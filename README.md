# AiPersona

An embeddable, on-device long-term memory engine for AI chat apps on Apple platforms. `AiPersona`
is a from-scratch Swift Package reimplementation of [synapse-cortex](https://github.com/juandastic/synapse-cortex)'s
*cognitive core* — a temporal knowledge graph, hybrid (BM25 + embedding) retrieval, and
LLM-driven fact extraction/correction — reshaped for a single-user, embedded, multi-provider
target instead of a multi-tenant server.

It gives a chat app the ability to say "I remember" and mean it: facts mentioned in past
conversations are extracted, stored in a small local knowledge graph, and surfaced back into
future system prompts — without a backend, without an account system, and without sending the
user's data anywhere unless the host app opts into an external LLM/embedding provider.

## What this is (and isn't)

- **Is:** a headless library. It stores and retrieves memory; it does not run a chat loop.
- **Is:** fully on-device by default — local extraction (via a host-supplied MLX model) and local
  embeddings ([`NLEmbedding`](https://developer.apple.com/documentation/naturallanguage)), with
  SwiftData as the on-disk store.
- **Is:** multi-provider — extraction and chat generation are independently selectable between
  on-device MLX, Gemini, OpenAI, and Anthropic.
- **Isn't** a chat completions API or SSE server — synapse-cortex is a FastAPI backend; this
  package builds *prompt fragments* for a host app's own chat loop to consume.
- **Isn't** multi-tenant — one local user per host app instance, by design.

See [`source-compared.md`](source-compared.md) for a feature-by-feature comparison against
synapse-cortex's README.

## Requirements

- Swift 5.10+
- macOS 14+ / iOS 17+
- Depends on [`AIChatKit`](https://github.com/NerdSnipe-Inc/AIChatKit) (`AIChatCore`,
  `AIChatOpenAI`, `AIChatAnthropic`) and [`AIChatKitMLX`](https://github.com/NerdSnipe-Inc/AIChatKitMLX)
  (`AIChatMLX`) — resolved from a sibling checkout (`../AIChatKit`, `../AIChatKitMLX`) if present,
  otherwise from GitHub. Set `SPI_PROCESSING` or `FORCE_REMOTE_PACKAGES` to force the remote
  resolution path (see `Package.swift`).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/NerdSnipe-Inc/AiPersona.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["AiPersona"]),
]
```

## Architecture at a glance

```
                     ┌─────────────────────┐
  chat turn  ───────▶│   IngestionActor    │──▶ MemoryProvider.extractFacts()
                     │   (background)      │        │
                     └─────────┬───────────┘        ▼
                               │            [ExtractedFact] (JSON, LLM-produced)
                               ▼
                     ┌─────────────────────┐
                     │  MemoryGraphStore   │  SwiftData: EntityNode / EpisodicNode / FactEdge
                     │  (fuzzy dedup,      │  bi-temporal — corrections invalidate, never delete
                     │  bi-temporal facts) │
                     └─────────┬───────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                  ▼
    RetrievalService.sessionCompilation()   RetrievalService.perTurnMemoryBlock()
    (cached, budgeted, per-session)         (BM25 + embedding hybrid search, RRF)
              │                                  │
              └────────────────┬─────────────────┘
                                ▼
                   PersonaPromptBuilder → prompt fragments
                                │
                                ▼
                  host app's own chat system prompt + LLM call
```

Plus three integrations that hang off the graph without changing the core loop: **Notion
export/import**, **knowledge-graph visualization export**, and **Gemini context caching**.

## Core concepts

### The graph: `MemoryGraphStore`

Three SwiftData models (`Sources/AiPersona/Memory/MemoryModels.swift`):

- **`EntityNode`** — a person/place/concept, with `name`, `summary`, `kind`
  (`.user`/`.subject`/`.other`), an L2-normalized `embedding`, and `aliases` (alternate names
  fuzzy-resolved onto this node).
- **`EpisodicNode`** — a raw conversation episode fed into extraction.
- **`FactEdge`** — a bi-temporal fact: `subjectID`, optional `objectID`, `predicate`, `factText`,
  `embedding`, `validAt`, and `invalidAt`. Corrections set `invalidAt` — **facts are never
  deleted**, only invalidated, so history is always reconstructable.

`MemoryGraphStore` (`@MainActor`, `.shared` singleton) wraps its own isolated `ModelContainer`
(`AiPersonaMemory.store` under Application Support — deliberately separate from any store a host
app manages itself, to avoid schema collisions):

```swift
let store = MemoryGraphStore.shared

let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers",
              factText: "prefers concise replies", embedding: LocalEmbedder.embed("prefers concise replies"))

store.activeFacts()          // facts with invalidAt == nil
store.allFacts()             // full history, including invalidated
store.allEntities()
store.visualizationExport()  // react-force-graph-shaped {nodes, links}
```

**Entity resolution.** `upsertEntity` tries an exact case-insensitive name/alias match first,
then falls back to `EntityNameMatcher` — deterministic token-subset and initials matching (e.g.
`"Juan"` ⊆ `"Juan Gómez"`, `"JG"` == initials of `"Juan Gómez"`). This is *not* embedding
similarity: word-vector embeddings have no coverage for proper nouns (verified empirically — see
`EntityNameMatcher`'s doc comment), so cosine similarity between two names is always 0 and can't
solve this problem at all. A fuzzy match is stored as an alias rather than overwriting the
canonical name, so the original extracted spelling is never lost.

**Correction invalidation.** `invalidateFacts(subjectID:objectID:relatedTo:minimumSimilarity:)`
matches a correction to the fact(s) it's actually about, regardless of predicate string (a
correction's predicate is rarely a literal match, e.g. `"wants"` → `"no longer wants"`). When
`objectID` is `nil` (the common case — most personal facts share the same subject), it
invalidates only the single most cosine-similar active fact above `minimumSimilarity`, favoring
under-correction over risking an unrelated fact being wiped. It returns `Bool` — whether anything
was actually invalidated — so a caller can surface "I'm not sure what to update" instead of the
correction silently doing nothing.

### Ingestion: `IngestionActor`

```swift
let episode = ChatEpisode(userText: "I prefer short answers", assistantText: "Got it.", occurredAt: .now)
let failedCorrections = await IngestionActor.shared.enqueue(episode, provider: someMemoryProvider, store: .shared)
```

Runs extraction via a `MemoryProvider`, merges/dedupes entities, and adds or invalidates facts.
It's a Swift `actor`, so concurrent `enqueue` calls against `.shared` are naturally serialized —
that also protects against extraction-provider rate limits without any extra concurrency-limiting
code. Extraction failures are logged and swallowed (ingestion is a background enhancement, never
something that should surface as a user-facing error). The return value is the list of
corrections that matched nothing to invalidate — call sites can use this to tell the user their
correction didn't land, instead of it disappearing silently.

### Retrieval: `RetrievalService`

Two layers, mirroring synapse-cortex's hydration + per-turn GraphRAG split:

```swift
let retrieval = RetrievalService.shared

retrieval.startNewSession()                 // clears the cached compilation
let compilation = retrieval.sessionCompilation()   // most recent `factLimit` (default 20) active facts, cached until the next new session
let topUp = retrieval.perTurnMemoryBlock(forQuery: userMessage, excluding: compilation)
// topUp: hybrid-search results (BM25 + embedding, RRF-fused) for facts not already in `compilation`, or nil
```

- `BM25Scorer` — standard BM25, recomputed fresh per call over the active-fact set (no
  persistent index — fine at personal-assistant scale; a documented future optimization if
  profiling ever says otherwise).
- `LocalEmbedder` — `NLEmbedding.wordEmbedding(.english)`-based, averaged and L2-normalized. Used
  for **all** memory embeddings regardless of which provider does extraction/chat, so the whole
  graph shares one embedding space (and because Anthropic has no embeddings API of its own).
- `HybridSearch` — fuses BM25 and embedding rankings via Reciprocal Rank Fusion.

### Persona: `PersonaStore` + `PersonaPromptBuilder`

```swift
PersonaStore.shared.update(name: "Nova", personality: "Warm, witty, and to the point.")

let systemPrompt = PersonaPromptBuilder.identityPreamble(name: PersonaStore.shared.name, personality: PersonaStore.shared.personality)
    + "\n\n" + yourAppsOwnInstructions
    + PersonaPromptBuilder.memorySection(compilation + (topUp.map { "\n" + $0 } ?? ""))
```

`identityPreamble` unconditionally tells the model it has persistent memory — omitting this
causes on-device models to reflexively deny having memory the instant a user says "remember X",
even before any fact has been extracted (verified against real behavior, not a guess).
`memorySection` returns `""` for empty/`nil` context so it's safe to unconditionally append.
`PersonaPromptBuilder` builds *fragments only* — composing them into a complete system prompt
(with the host app's own tool-use/safety instructions) is the host app's job.

### Provider selection & secrets: `MemorySettingsStore` + `PersonaKeychain`

```swift
MemorySettingsStore.shared.selectExtractionProvider(.gemini)
MemorySettingsStore.shared.selectChatProvider(.local)
MemorySettingsStore.shared.setAPIKey("...", for: .gemini)
```

Extraction and chat-generation providers are independently selectable among `.local`, `.gemini`,
`.openAI`, `.anthropic`. API keys are stored in the Keychain via a small, dependency-free
`PersonaKeychain` wrapper (kept independent of any host app's own Keychain helper, so this
package stays a self-contained, reusable unit).

## Memory providers

`MemoryProvider` is the extraction protocol every backend implements:

```swift
public protocol MemoryProvider: Sendable {
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact]
}
```

- **`LocalMemoryProvider`** — extraction via a host-supplied on-device MLX model. No API key, no
  network. Accepts a `serialize` closure so a host app can route generation through its own
  serialization mechanism (this package has no opinion on one).
- **`ExternalMemoryProvider`** — wraps any `ChatProvider` (Gemini/OpenAI/Anthropic all conform)
  as a `MemoryProvider`; the extraction call is just `complete(...)` with a shared JSON-array
  extraction prompt (`ExtractionPromptFormat`).
- **`MemoryProviderFactory.makeExtractionProvider(...)`** — builds the active provider from
  `MemorySettingsStore.extractionProvider`, falling back to local if a selected external
  provider's API key is missing (extraction is a background enhancement — it should never
  hard-fail the pipeline over a misconfigured setting).
- **`GeminiProvider`** — this package's own `ChatProvider` conformance for Gemini (the one
  backend `AIChatKit` doesn't already ship). Sends the API key via the `x-goog-api-key` header,
  never the URL.

All extraction prompts ask for the same JSON contract
(`ExtractionPromptFormat.instruction`/`.parse`) — an array of `{subjectName, objectName,
predicate, factText, isCorrection}`, defensively parsed (extraction of a `[...]` substring even
if the model wraps it in prose) and never throwing on malformed output.

## Integrations

Three features from synapse-cortex's README that this package implements as **direct REST
integrations, no server or agent framework required** — a deliberate design choice: these APIs
(Notion, Gemini caching) are plain HTTPS resources callable with a bearer/API-key token from any
client, so there's no architectural reason they need a backend the way synapse-cortex has one.

### Notion export / correction import

```swift
NotionSettingsStore.shared.setIntegrationToken("secret_...")
NotionSettingsStore.shared.setParentPageID("...")

let client = NotionClient(token: NotionSettingsStore.shared.integrationToken!)
let databaseID = try await NotionExportService.export(
    store: .shared, client: client, parentPageID: NotionSettingsStore.shared.parentPageID!
)

// Later, after a user edits rows in Notion (checks "Needs Review", writes "Correction Notes"):
let failedRows = try await NotionCorrectionImportService.importCorrections(
    client: client, provider: someMemoryProvider, store: .shared, databaseID: databaseID
)
```

Export creates a Notion database (fixed schema: name, kind, fact, valid-from, needs-review,
correction-notes) and one page per active fact. Import queries rows flagged "Needs Review",
routes each row's "Correction Notes" text through `IngestionActor.enqueue` (reused as-is, not
reimplemented) as a synthetic chat turn, clears the flag on success, and returns the rows that
matched nothing so they aren't silently marked resolved.

### Knowledge graph visualization

```swift
let export = MemoryGraphStore.shared.visualizationExport()
// GraphVisualizationExport { nodes: [{id, name, kind}], links: [{source, target, label}] }
let json = try JSONEncoder().encode(export)
```

A pure mapping to `react-force-graph`-shaped JSON. Facts with no `objectID` (most personal facts
— "User prefers dark mode" has no second entity) don't produce a link; they're node-attribute
shaped, not graph-edge shaped. Rendering is the host app's job — this stays headless.

### Gemini context caching

```swift
let cacheClient = GeminiCacheClient(apiKey: geminiAPIKey)
let cacheService = GeminiContextCacheService.shared

let cacheName = await cacheService.cacheName(for: compilation, model: "gemini-2.5-flash", client: cacheClient)
let result = try await GeminiProvider(apiKey: geminiAPIKey).complete(
    messages: messages, model: "gemini-2.5-flash", options: options, cachedContentName: cacheName
)
```

Reuses a Gemini `cachedContents` entry across a session's turns instead of resending the full
compilation every time (~75% input-token cost reduction on repeated turns, per Gemini's own
caching economics). Size-gated (skips caching below `minimumCacheableCharacters`, default ~4000
— an approximation of Gemini's ~1k-token minimum, since this package has no real tokenizer);
reuses + TTL-refreshes the cache for an unchanged compilation; creates a fresh cache when the
compilation changes; returns `nil` on any failure so the caller falls back to inlining the
compilation normally. Call `GeminiContextCacheService.reset()` alongside
`RetrievalService.startNewSession()` so a new session doesn't reuse a stale cache reference.

## Design decisions worth knowing about

- **Never deletes.** Every mutation to the graph is additive or an invalidation timestamp.
  History is always reconstructable via `allFacts()`.
- **Conservative corrections.** A correction that doesn't clearly match an existing fact does
  nothing, rather than guessing and risking wiping the wrong fact.
- **One embedding space.** All embeddings — regardless of which LLM provider does extraction or
  chat — come from the same on-device `LocalEmbedder`, so hybrid search is meaningful across
  provider switches.
- **No agent loops.** Every pipeline here (extraction, retrieval, Notion sync, Gemini caching) is
  a deterministic sequence of calls, not an LLM-driven tool-calling loop — same philosophy
  synapse-cortex itself uses for its ~1s-latency retrieval path.
- **Testing convention.** HTTP-calling types (`GeminiProvider`, `NotionClient`,
  `GeminiCacheClient`) split request-building and response-parsing into pure, internally-testable
  functions; the actual `URLSession` calls are thin wrappers over those and aren't unit-tested
  directly. Orchestration logic with real branching (`NotionExportService`,
  `NotionCorrectionImportService`, `GeminiContextCacheService`) is tested against a protocol-based
  stub (`NotionAPIClient`/`GeminiCacheAPIClient`) instead of the network.

For the full list of what's implemented and what's a deliberate simplification vs.
synapse-cortex, see [`source-compared.md`](source-compared.md) (feature-by-feature comparison).

## Testing

```sh
swift test
```

94 tests across extraction, ingestion, memory graph, persona, providers, retrieval, and the
Notion/Gemini-caching integrations — one test file per source file.
