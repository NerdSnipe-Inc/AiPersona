# AiPersona architecture

How a chat turn becomes memory, and how memory comes back into the next prompt.

```
            ┌───────────── host app (e.g. AICompleteChat) ─────────────┐
 user text  │ PersonaChatCoordinator.send                               │
 ─────────► │   1. RetrievalService.sessionCompilation()  (cached)      │
            │   2. RetrievalService.perTurnMemoryBlock(query)           │
            │   3. system prompt = PersonaPromptBuilder.identityPreamble│
            │                    + memorySection(1+2)                   │
            │   4. ChatSession.send  ──► MLXProvider.stream ──► reply   │
            │   5. on turn complete (no error, non-empty reply):        │
            │        Task { IngestionActor.enqueue(episode, provider) } │
            └───────────────────────────────────────────────────────────┘
                                   │ episode text ("user: …\nassistant: …")
                                   ▼
        MemoryProvider.extractFacts  (LocalMemoryProvider → MLXProvider.complete,
                                      or ExternalMemoryProvider → Gemini/OpenAI/Anthropic)
                                   │ raw model text
                                   ▼
        ExtractionPromptFormat.parseDetailed   (tolerant JSON scan, see below)
                                   │ [ExtractedFact]
                                   ▼
        IngestionActor (actor)  ── filters junk/pronouns/transients
                                ── canonicalizes "the user" → known user name
                                ── dedupes exact + near-duplicate (cosine ≥ 0.85)
                                ── isCorrection → invalidate matching fact
                                       (never a user-edited one → PendingCorrection)
                                   ▼  (hops to @MainActor)
        MemoryGraphStore  (SwiftData: EntityNode / FactEdge / EpisodicNode, bi-temporal)
```

## Pieces

| Piece | File | Notes |
|---|---|---|
| `MemoryGraphStore` | `Memory/MemoryGraphStore.swift` | `@MainActor`, own `ModelContainer` under `Application Support/<bundle id>/AiPersonaMemory.store`. Facts are never deleted by ingestion, only given `invalidAt`. Save/fetch failures are logged (they used to be swallowed). |
| `IngestionActor` | `Ingestion/IngestionActor.swift` | Extraction happens on the actor (off the main thread); the graph merge happens in one `MainActor.run`. Extraction errors are logged and skipped — ingestion never surfaces a user-visible error. |
| `ExtractionPromptFormat` | `Providers/MemoryProvider.swift` | The extraction prompt and the parser. |
| `LocalMemoryProvider` | `Providers/LocalMemoryProvider.swift` | Calls the on-device `MLXProvider`. Logs the raw model output when it cannot be parsed. |
| `RetrievalService` | `Retrieval/RetrievalService.swift` | Two layers: a per-session cached "compilation" (top `factLimit`=20 facts by entity degree, then recency) and a per-turn hybrid (BM25 + `NLEmbedding` cosine, RRF) top-up. |
| `PersonaPromptBuilder` | `Persona/PersonaPromptBuilder.swift` | Identity preamble (name, personality, "you have persistent memory", current date) + `### RELEVANT MEMORY ###` block. |

## The parser is deliberately forgiving

`ExtractionPromptFormat.parseDetailed` does **not** slice first-`[`-to-last-`]` and `Codable`-decode
(the original approach lost *every* fact if the preamble contained a `[`, or if one element was
malformed). It strips `<think>…</think>` / `<|channel>thought…<channel|>`, then scans for balanced,
string-aware `{…}` objects and keeps each that has a `subjectName` and `factText`. That handles
markdown fences, prose around the JSON, a bare object, a `{"facts":[…]}` wrapper, output truncated by
`maxTokens` (complete objects before the cut survive), `"objectName": "null"`, and a missing or
string-typed `isCorrection`. Input is capped at 32k scalars (brace matching is quadratic on garbage).
`ParseResult.looksUnparseable` distinguishes "the model correctly said `[]`" from "the model said
something unreadable" so the second case is logged with the raw text.

## Concurrency model

* `MemoryGraphStore` and `RetrievalService` are `@MainActor`. Retrieval scans all active facts
  synchronously on the main actor: ~0.15 s (compilation) + ~0.4 s (per-turn search) at 2,000 facts on
  Apple silicon (measured in `PersonaPipelineTests.hugeStore`). Beyond ~10k facts, move retrieval off
  the main actor or add an index.
* Extraction (`MLXProvider.complete`) and chat (`MLXProvider.stream`) both go through MLX's single
  `ModelContainer`, which serialises them. A background extraction therefore **delays** the next chat
  turn by up to one extraction (≈ 3–7 s with gemma-4-e4b) but cannot deadlock or corrupt it
  (`LivePersonaTests.ingestionOverlapsNextTurn`). Give extraction its own `MLXProvider` instance with
  `temperature: 0` and a `maxTokens` cap (AICompleteChat does): same model id ⇒ same resident weights,
  but deterministic, bounded output.
* `PendingCorrection.existingFact` is a live `@Model` reference: read it only on `@MainActor`.

## Error handling policy

* **Ingestion / extraction / reranking / Gemini caching**: best-effort background enhancements. They
  never throw to the user; every swallowed failure is logged (see below) so it can be diagnosed.
* **Gemini `complete`**: non-2xx now throws `ChatError.serverError(statusCode:message:)` with Google's
  own message instead of returning an empty string.
* **Keychain save failures** are logged (`Keychain` category).
* Corrections that could not be applied (`failedCorrections`) or that hit a hand-edited fact
  (`pendingReviewCorrections`) are returned in `EnqueueResult`; hosts should check `needsHumanReview`.

## Debug logging

All logging uses subsystem `cc.nerdsnipe.AiPersona`; categories: `Ingestion`, `Extraction`, `Store`,
`Retrieval`, `Gemini`, `Keychain`. User content (raw model output, fact text) is `privacy: .private`.

```sh
log stream --predicate 'subsystem == "cc.nerdsnipe.AiPersona"' --level debug
# just extraction problems:
log stream --predicate 'subsystem == "cc.nerdsnipe.AiPersona" AND category == "Extraction"' --level debug
# together with the chat kit's own logs (AIChatKit: set AICHAT_DEBUG=1 for verbose):
log stream --predicate 'subsystem BEGINSWITH "cc.nerdsnipe"' --level debug
```

Private strings show as `<private>` unless the process is attached to Xcode or you enable private
data logging (`sudo log config --mode "private_data:on"`).

## Known limits

* **Extraction quality is bounded by the 4-bit 4B model.** With `gemma-4-e4b-it-4bit` at temperature 0,
  "My name is Sam, I work at Acme as a nurse and I'm allergic to penicillin" yields the employer and
  the allergy but usually drops the "nurse" qualifier and the bare name fact. An attempted prompt
  change to demand them made extraction worse (subject/object confusion), so it was reverted.
* The model alternates between "Sam" and "the user" as subject across episodes; `IngestionActor`
  canonicalises the stand-in to the host-supplied `knownUserName`. With no known name the two remain
  distinct entities.
* Subject-only corrections match by word-vector cosine ≥ 0.5 (coarse); object-scoped corrections match
  exactly on subject + object.
* Embeddings are `NLEmbedding` word-vector averages: out-of-vocabulary technical words embed to
  nothing, so BM25 carries those queries.
* `LocalMemoryProvider` needs the model already downloaded or downloadable; if `loadModel()` throws,
  the episode is skipped (logged), not retried.
