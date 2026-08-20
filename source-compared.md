# AiPersona vs. synapse-cortex — Feature Comparison

Source: https://github.com/juandastic/synapse-cortex#core-features (reference project, server-side, Python/FastAPI/Neo4j/Graphiti). Compared against the README's 9 numbered Core Features 1:1.
Target: `AiPersona` (this package — Swift Package, on-device, SwiftData), reviewed at commit `5e49ce8` (2026-07-22); re-verified against current source and updated 2026-08-20 (entity resolution, memory CRUD primitives, extraction quality filtering, storage isolation).

**Correction (2026-08-20, second pass):** the previous 2026-08-20 re-verification missed that `Sources/AiPersona/Notion/` (export + correction import), `Sources/AiPersona/Providers/GeminiCacheClient.swift`+`GeminiContextCacheService.swift`, and `Sources/AiPersona/Memory/GraphVisualizationExport.swift` already existed — committed in the initial commit (`f1d7d3b`), before that pass ran, each with full test coverage under `Tests/AiPersonaTests/`. All four rows below previously marked ❌ for these features are corrected to ✅. None of the four are wired into `GeminiProvider`/`RetrievalService` automatically — consistent with this package's "host app composes" design, same as every other optional capability here.

Legend: ✅ Done · 🟡 Partial / simplified · ❌ Not implemented

## 0. Core Features (README, 1:1)

| # | synapse-cortex feature | AiPersona | Status |
|---|---|---|---|
| 1 | Knowledge Graph Ingestion (session processing, entity resolution, temporal awareness, degree-based filtering) | Session processing ✅, entity resolution 🟡 deterministic fuzzy matching (not LLM-driven), temporal awareness ✅, degree-based filtering ✅ (`EntityDegreeRanking`) | 🟡 Partial |
| 2 | OpenAI-Compatible Chat Completions (SSE streaming, Gemini backend, system-prompt injection) | Not a chat API by design — prompt-fragment builder only; Gemini backend ✅; system-prompt injection ✅ | ❌ Out of scope (chat API), ✅ Done (injection) |
| 3 | Smart Context Retrieval / Hydration (two-phase compilation, Cypher-optimized, connectivity-based ranking) | Single-phase fact-limit compilation, no connectivity/degree ranking | 🟡 Partial |
| 4 | GraphRAG per-turn retrieval (hybrid search + RRF, dedup, automatic gating, zero-LLM overhead) | ✅ Hybrid BM25+embedding RRF, ✅ dedup vs. compilation, ❌ no automatic gating (`is_partial` equivalent), ✅ deterministic no-agent-loop | 🟡 Mostly done |
| 5 | Gemini Context Caching (cached prefix, TTL refresh, size-gated, stateless) | ✅ `GeminiCacheClient` (REST against `cachedContents`) + `GeminiContextCacheService` (size-gated via `minimumCacheableCharacters`, TTL refresh on cache hit, stateless caller-supplied client) | ✅ Done |
| 6 | Knowledge Graph Visualization (React-Force-Graph node/link export, real-time corrections, temporal filtering) | ✅ `GraphVisualizationExport.build(fromEntities:activeFacts:)` maps `EntityNode`/`FactEdge` → `{nodes, links}`, exposed via `MemoryGraphStore.visualizationExport()`. Real-time corrections ✅ (via ingestion), temporal filtering ✅ (`activeFacts()`) | ✅ Done |
| 7 | Notion Export (graph→Notion pipeline, dynamic schema via Gemini, MCP agent, async+polling, feedback-loop columns, per-request auth) | ✅ `NotionExportService.export` + `NotionClient` — direct REST against `api.notion.com/v1`, fixed schema (not Gemini-dynamic), no MCP agent, synchronous (not async+polling), per-instance bearer token | 🟡 Done, simplified (fixed schema, sync, no polling) |
| 8 | Notion Correction Import (reads corrections from Notion, MCP agent row updates, `add_episode` w/ custom instructions, partial-failure handling) | ✅ `NotionCorrectionImportService.importCorrections` — reads "Needs Review" rows, routes each through `IngestionActor.enqueue` (no separate MCP agent), clears the flag on success, reports failed rows for partial-failure handling | ✅ Done |
| 9 | Security & Rate Limiting (API key auth header, concurrency semaphore, CORS) | API key auth ✅ (Keychain, header-based per commit `8cd8b97`), concurrency limiting ❌ not applicable (no server), CORS ❌ N/A (no server) | 🟡 Partial (server-shaped items N/A by design) |

Note: the previous pass merged features 7+8 into a single "Notion" row and had no dedicated row for feature 6 — both corrected above.

## 1. Core Architecture

| Aspect | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Runtime | Stateless REST API (FastAPI/Uvicorn), Docker/Digital Ocean | In-process Swift library, embedded in a host app (macOS 14+/iOS 17+) | 🟡 Different deployment model by design |
| Storage | Neo4j graph DB + vector index | SwiftData (`EntityNode`, `EpisodicNode`, `FactEdge`) in an on-disk store (`AiPersonaMemory.store`), namespaced under Application Support/`<host bundle ID>` — fixed from a shared, unnamespaced path where any two unsandboxed host apps on the same Mac would have read/written the same file | ✅ Equivalent graph shape, embedded engine, genuinely per-host-app isolated |
| Graph engine | Graphiti Core (temporal KG library) | Hand-rolled equivalent (`MemoryGraphStore`) | ✅ Core semantics reproduced, not the library |
| Multi-tenant / multi-user | Yes — per-request auth, stateless cache-name ownership | No — single local user/persona per host app instance | ❌ Not applicable to on-device use case |

## 2. Knowledge Graph & Entities

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Entity nodes (people, places, concepts) | ✅ Graphiti `Entity` | ✅ `EntityNode` (`Sources/AiPersona/Memory/MemoryModels.swift:13`) | ✅ Done |
| Episodic nodes (raw conversation) | ✅ Graphiti `Episodic` | ✅ `EpisodicNode` (`MemoryModels.swift:39`) | ✅ Done |
| Relationship/fact edges | ✅ Graphiti edges with facts + timestamps | ✅ `FactEdge` (`MemoryModels.swift:55`) | ✅ Done |
| Temporal validity (`valid_at`/`invalid_at`) | ✅ | ✅ Same fields, same semantics — never deletes, only invalidates (`MemoryGraphStore.swift:76-120`) | ✅ Done |
| Entity resolution / dedup ("Juan", "JG" → one node) | ✅ LLM-driven fuzzy resolution via Graphiti | 🟡 `upsertEntity` tries exact case-insensitive match first, then deterministic fuzzy matching via `EntityNameMatcher` (token-subset containment + initials matching, e.g. "Juan" ⊆ "Juan Gómez", "JG" == initials of "Juan Gómez") — no longer exact-match-only, but still not LLM/embedding-driven; word-embedding similarity was tried and explicitly ruled out (`EntityNameMatcher.swift:1-9`) since proper nouns have no entry in the general-English embedding vocabulary | 🟡 Partial (deterministic heuristic, not LLM resolution) |
| Degree-based / confidence-based entity ranking | ✅ Used in hydration to exclude low-confidence entities | ✅ `EntityDegreeRanking` — counts active-fact connections per entity, ranks `sessionCompilation()`'s candidate facts by subject-entity degree (descending) before recency, so budget-constrained hydration favors well-connected entities over one-off mentions (`RetrievalService.swift`) | ✅ Done |
| LLM-driven entity/relationship extraction | ✅ Graphiti + Gemini | ✅ Same idea: any `MemoryProvider` (local MLX, Gemini, OpenAI, Anthropic) extracts `[ExtractedFact]` via a JSON-array prompt contract (`MemoryProvider.swift`) | ✅ Done |

## 3. Memory Correction

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Natural-language corrections update the graph | ✅ | ✅ Extraction call flags `isCorrection`; ingestion invalidates rather than deletes | ✅ Done |
| Correction targeting precision | Graphiti auto-invalidates the specific outdated edge | 🟡 Subject+object match invalidates all matches; subject-only corrections use cosine-similarity against a `minimumSimilarity` threshold to invalidate the *single* most-similar active fact, no-op if nothing clears the bar (`MemoryGraphStore.swift:104-120`) | 🟡 Partial, deliberately conservative |
| Temporal integrity maintained | ✅ | ✅ | ✅ Done |

## 4. Retrieval

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Full context "hydration" (session-level compilation) | ✅ V1 (full dump) / V2 (budget-aware, ~120k chars) | 🟡 `RetrievalService.sessionCompilation()` — most recent `factLimit` (default 20) active facts by `validAt`, cached until `startNewSession()`. No character-budget accounting, single fixed strategy | 🟡 Partial |
| Per-turn supplemental retrieval (GraphRAG) | ✅ Hybrid semantic + BM25 via Graphiti, dedup vs. hydrated base | ✅ `perTurnMemoryBlock` — hybrid search over facts not already substring-present in the compilation (`RetrievalService.swift:36-51`) | ✅ Done, same shape |
| BM25 scoring | ✅ (via Graphiti/Neo4j) | ✅ Standard BM25 implemented from scratch, computed fresh per call, no persistent index (`BM25Scorer.swift`) | ✅ Done |
| Semantic/embedding search | ✅ Gemini `gemini-embedding-001` | 🟡 `NLEmbedding.wordEmbedding` averaged across words, L2-normalized (`LocalEmbedder.swift`) — coarser than a sentence-embedding model, on-device only, no external embedding API used | 🟡 Partial (weaker embedding quality, but zero-setup) |
| Hybrid fusion method | Graphiti's `HYBRID_SEARCH_RRF` | ✅ Reciprocal Rank Fusion, same formula (`HybridSearch.swift`) | ✅ Done |
| Reranking | ✅ Gemini reranking | ❌ No reranking step | ❌ Not implemented |
| Automatic retrieval gating (skip GraphRAG when graph already fits in prompt) | ✅ `is_partial: false` short-circuits per-turn retrieval | ❌ `perTurnMemoryBlock` always runs the hybrid search, no "graph fits in compilation" skip check | ❌ Not implemented |
| Retrieval latency profile | ~1s deterministic, no agent loop | ✅ Same philosophy — deterministic pipeline, no tool-calling/agent loop | ✅ Done (design parity) |

## 5. Chat / LLM Integration

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| OpenAI-compatible streaming chat API | ✅ SSE-based REST endpoint | ❌ Not a chat API — this package only builds prompt fragments (`PersonaPromptBuilder`) for a host app's own chat loop | ❌ Out of scope by design |
| Gemini as LLM backend | ✅ Primary/only backend | ✅ `GeminiProvider` implemented directly against `generateContent` (non-streaming underneath; `stream` wraps it as one `.text` event) | ✅ Done |
| Multiple LLM providers | ❌ Gemini only | ✅ Local (on-device MLX), Gemini, OpenAI, Anthropic — independently selectable for extraction vs. chat (`MemorySettingsStore`, `MemoryProviderFactory`) | ✅ Exceeds source |
| System-prompt injection of user knowledge | ✅ | ✅ `PersonaPromptBuilder.memorySection` + explicit "you have persistent memory" identity preamble (added specifically to stop the on-device model from denying it has memory) | ✅ Done |
| Persona/personality configuration | Implicit in system design | ✅ `PersonaStore` — name + personality, host app composes into its own system prompt | ✅ Exceeds source (not a synapse-cortex concept) |

## 6. Caching / Cost Optimization

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Gemini context caching (~75% cost reduction) | ✅ Explicit cached-prefix management, stateless client-owned cache names | ✅ `GeminiContextCacheService` — same shape, not wired into `GeminiProvider` automatically (host app opts in) | ✅ Done (standalone service) |
| Cost-aware retrieval budget | ✅ V2 hydration budget (~120k chars) | ❌ Fixed `factLimit`/`limit` integers, no token/character budget logic | ❌ Not implemented |

## 7. External Integrations

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Notion Export (graph → Notion DBs, Gemini-designed dynamic schema, MCP agent, async+polling, feedback-loop columns) | ✅ Full pipeline via `create_react_agent` + Notion MCP server | ✅ Direct REST pipeline (`NotionExportService`+`NotionClient`) — fixed schema instead of Gemini-designed, no MCP agent, synchronous instead of async+polling, feedback-loop columns present ("Needs Review"/"Correction Notes") | 🟡 Done, simplified |
| Notion Correction Import (reads corrections from Notion, MCP agent updates/deletes rows, `add_episode` w/ `custom_extraction_instructions`, partial-failure handling) | ✅ Full pipeline | ✅ `NotionCorrectionImportService` — routes each flagged row through the existing `IngestionActor.enqueue` correction path instead of a separate MCP agent; returns failed rows for partial-failure handling | ✅ Done |
| Knowledge Graph Visualization (React-Force-Graph node/link export format, temporal filtering) | ✅ Dedicated endpoint returning nodes/links shaped for frontend rendering | ✅ `MemoryGraphStore.visualizationExport()` → `GraphVisualizationExport` (`{nodes, links}`), built from `activeFacts()` so temporal filtering is inherent | ✅ Done |
| Any general UI for browsing/editing memory | ✅ Via Notion | 🟡 Still a headless library — no UI ships in this package — but the CRUD primitives a UI needs now exist: `updateEntity(id:name:summary:)`, `deleteEntity(id:)`, `updateFact(id:factText:)` (`MemoryGraphStore.swift:248,261,276`), alongside the existing `upsertEntity`. A host app (AICompleteChat) has built a real browse/edit UI on top of these. | 🟡 Partial (library primitives done, no bundled UI) |

## 8. Security / Secrets

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| API key handling | Server-side env config | ✅ Per-provider API keys in Keychain via `PersonaKeychain` (`MemorySettingsStore.apiKey`) | ✅ Done, appropriate for on-device |
| Gemini key transport | N/A (server-side) | ✅ Sent via `x-goog-api-key` header (fixed from URL query string per commit `8cd8b97`) | ✅ Done |

## 9. Testing

| Area | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Test coverage | Unknown (not reviewed) | ✅ 14 test files covering every source file 1:1 (Ingestion, Memory, Persona, Providers, Retrieval) | ✅ Present |

---

## Summary Table

| Category | Status |
|---|---|
| Temporal knowledge graph model | ✅ Done |
| LLM-driven fact extraction | ✅ Done (and multi-provider, exceeding source) |
| Memory correction / invalidation | 🟡 Partial (conservative, similarity-gated) |
| Entity resolution / dedup | 🟡 Partial (deterministic fuzzy matching now closes the exact-match gap; still not LLM-driven) |
| Degree-based entity ranking | ✅ Done (`EntityDegreeRanking`) |
| Hydration (session compilation) | 🟡 Partial (no character-budget strategy) |
| Per-turn GraphRAG-style retrieval | ✅ Done |
| BM25 + embedding hybrid search (RRF) | ✅ Done |
| Automatic retrieval gating (skip when compilation already covers the graph) | ❌ Not implemented |
| Reranking | ❌ Not implemented |
| Multi-provider LLM support | ✅ Done (exceeds source — source is Gemini-only) |
| System prompt injection | ✅ Done |
| Gemini context caching | ✅ Done (standalone service, not auto-wired) |
| Cost/budget-aware retrieval | ❌ Not implemented |
| Notion export | 🟡 Done, simplified (fixed schema, sync, no MCP agent) |
| Notion correction import | ✅ Done |
| Knowledge graph visualization (node/link export) | ✅ Done |
| Chat completions API (server) | ❌ Out of scope (different product shape) |
| Memory browsing/editing UI (general) | 🟡 Partial (CRUD primitives — `updateEntity`/`deleteEntity`/`updateFact` — done; no UI bundled in this package) |
| Extraction quality filtering (junk-entity/transient-fact rejection, near-duplicate dedup) | ✅ Done (not tracked by source — on-device-model-specific reliability issue); extended 2026-08-20 with embedding-similarity near-duplicate detection (`IngestionActor.duplicateSimilarityThreshold`) and prompt-level negative examples, to address reworded-restatement re-saves observed in practical use |
| Multi-tenant/stateless server model | ❌ Not applicable (on-device single-user design) |

---

## Detailed Review & Recommendations

**What this package actually is.** AiPersona is not a port of synapse-cortex — it's a from-scratch, on-device reimplementation of synapse-cortex's *cognitive core* (temporal knowledge graph + hybrid retrieval + LLM-driven extraction/correction), deliberately stripped of everything that only makes sense for a multi-tenant server product (Neo4j, Docker, Notion, a chat completions API, multi-tenant auth). That's the right scope decision for a Swift Package meant to be embedded in a host app — trying to reproduce the REST-API/Neo4j/Notion surface area would fight the target platform rather than serve it.

**Where the reimplementation is genuinely strong.** The temporal fact model (bi-temporal `validAt`/`invalidAt`, never-delete semantics), the BM25+embedding RRF hybrid search, and the two-layer retrieval split (cached session compilation + per-turn top-up excluding what's already surfaced) all mirror synapse-cortex's actual mechanics rather than just its vocabulary. The multi-provider abstraction (local MLX / Gemini / OpenAI / Anthropic, independently selectable for extraction vs. chat) is a real improvement over the source, which is hard-wired to Gemini. Code comments throughout show these design choices were made deliberately and validated against real bugs (e.g. the SwiftData store-collision fix, the persona preamble fix, the correction-targeting narrowing) — this is not vibe-coded; it reads as carefully reasoned.

**Update — entity resolution is no longer exact-match only.** The original review's #1 highest-priority gap has since been closed with a deterministic (not LLM/embedding-driven) fuzzy matcher: `EntityNameMatcher` catches token-subset containment ("Juan" ⊆ "Juan Gómez") and initials ("JG" == initials of "Juan Gómez"), wired into `upsertEntity` as a second-pass fallback after exact match. Embedding similarity was tried first and explicitly abandoned — proper nouns like personal names generally have no entry in the general-English word-embedding vocabulary `LocalEmbedder` uses, so cosine similarity between two names was always 0. Remaining gap: still not LLM-driven resolution, so cases outside token-subset/initials patterns (nicknames, transliteration variants) won't merge. Lower priority than before, but not zero.

**The remaining simplification most likely to bite in practice:**

1. **Junk extraction was a real, observed production bug — now mitigated, not eliminated.** The extraction prompt originally said "extract every distinct fact... mentioned," with no importance filter and no pronoun resolution — this produced literal junk in production: an entity named `"I"` (the model taking a first-person pronoun as a literal name when it had no resolved identity to substitute), and facts like `"The current date is Thursday, August 20, 2026."` persisted as permanent memories once the system prompt started stating the date every turn. Fixed at two levels: the extraction prompt (`MemoryProvider.swift`'s `ExtractionPromptFormat.instruction`) now explicitly filters for durable, future-useful facts, excludes transient/self-evident info, and accepts a `"Known user name: X"` context line so first-person references resolve to a real name when available (threaded from a new `PersonaStore.userName` field via `IngestionActor.enqueue(_:provider:store:knownUserName:)`); and `IngestionActor` itself now has a code-level backstop (drops pronoun-subject/object facts, drops current-date/time-phrased facts, skips exact-duplicate facts — `addFact` itself still has no dedup) since prompt compliance on a small on-device model is never guaranteed. This isn't a synapse-cortex parity gap (the source doesn't document this problem at all, likely because Gemini as a much larger model is less prone to it) — it's a real reliability issue specific to running extraction on a small on-device model, now covered by 5 regression tests but not eliminated at the root (a sufficiently confident but wrong extraction still isn't caught by either layer).

   **Update (2026-08-20):** a further practical-use complaint — too many low-value facts being saved overall, not just the two specific junk patterns above — traced to two gaps: the prompt had no negative examples beyond the abstract "small talk"/"transient" framing (nothing telling the model not to extract greetings, the user's own questions, momentary state, or a thin fact invented just to justify naming an entity mentioned once in passing), and dedup was exact-text only, so the same preference re-saved every conversation with slightly different wording (e.g. "prefers dark mode" vs. "really likes dark mode") landed as a second row every time. Fixed: `ExtractionPromptFormat.instruction` gained concrete negative examples and a "most turns produce zero facts" framing; `IngestionActor` gained `duplicateSimilarityThreshold` (0.85), extending dedup to catch embedding-similarity near-duplicates via `LocalEmbedder`, calibrated against real output (reworded restatements measured ~0.89-0.90 similarity, unrelated facts sharing a subject measured ~0.35). Deliberately not added: a minimum-content-word floor (risked dropping legitimate short facts like "prefers dark mode") and a cross-session entity-creation threshold (would need `MemoryGraphStore` recurrence tracking — a single-episode heuristic would be guessing).

2. **Correction invalidation for subject-only facts is a similarity threshold, not true resolution.** The current approach (invalidate the single most-similar active fact above `minimumSimilarity`, else no-op) is a reasonable, safety-first stopgap — it explicitly favors under-correcting over wrongly wiping unrelated facts — but it means some genuine corrections will silently fail to apply if similarity falls just under the bar, with no user-visible signal that the correction "did nothing." Worth deciding whether that failure mode should ever surface (e.g. a debug log, or returning a bool from `invalidateFacts` so a host app *could* choose to tell the user "I'm not sure what to update").

**Correction (2026-08-20, second pass) — Notion export/import, Gemini caching, and graph visualization are already built, not gaps.** An earlier pass of this review had corrected an even-earlier assumption that these needed a server or MCP-agent runtime — that correction was right in principle (they're plain REST calls: `api.notion.com/v1` bearer-token and `generativelanguage.googleapis.com/v1beta/cachedContents` using the same key `GeminiProvider` already sends as a header) but stopped short of noticing the code already existed. `Sources/AiPersona/Notion/` (`NotionClient`, `NotionExportService`, `NotionCorrectionImportService`), `Sources/AiPersona/Providers/GeminiCacheClient.swift`+`GeminiContextCacheService.swift`, and `Sources/AiPersona/Memory/GraphVisualizationExport.swift` were all present in the initial commit, each with test coverage under `Tests/AiPersonaTests/`. Notion export takes a fixed schema instead of a Gemini-designed dynamic one and runs synchronously instead of async+polling — real, minor simplifications — but the feature-shape gap this review previously tracked doesn't exist.

**What's genuinely out of scope, re-checked individually rather than assumed:** the OpenAI-compatible *SSE server endpoint* specifically (feature 2 — requires listening for inbound HTTP requests, which an embedded library cannot do; the underlying chat-generation capability itself already exists via `ChatProvider`/`GeminiProvider.complete`), multi-tenant per-request auth (feature 9 — meaningless for a single-user library; one Keychain token per provider is the correct equivalent), and CORS (feature 9 — a browser cross-origin concept with no applicable surface here). Checked and ruled out as a gap, not just assumed away: concurrency-limiting against provider 429s (feature 9's semaphore) — `IngestionActor` is a Swift `actor`, so concurrent `enqueue` calls are already serialized by the language's actor isolation, achieving the same practical effect without an explicit limiter.

Automatic retrieval gating and reranking (feature 4) remain genuinely lower-priority — not because they're server-only, but because they matter more at graph/traffic scales this package isn't likely to reach on a personal device; worth revisiting if usage data says otherwise. Degree-based entity ranking (feature 1) is no longer in that bucket — implemented 2026-08-20 via `EntityDegreeRanking`, ranking `sessionCompilation()`'s budget-constrained facts by subject-entity connection count before recency.

**One structural risk worth flagging, not a feature gap:** `MemoryGraphStore`, `RetrievalService`, `PersonaStore`, and `MemorySettingsStore` are all `@MainActor` singletons. That's fine for a small local dataset today, but `BM25Scorer`/`HybridSearch` recompute over the *entire* active-fact set on every call with no persistent index — documented as an intentional simplification ("future optimization if profiling ever shows otherwise"). Worth keeping an eye on once a host app's users accumulate thousands of facts; recomputing full BM25 on the main actor on every chat turn is the kind of thing that's invisible in testing and shows up as UI jank in the field.

**Overall assessment:** the package has faithfully captured synapse-cortex's core cognitive-loop *ideas* (temporal graph, hybrid retrieval, correction-via-invalidation, LLM-driven extraction) in an architecture appropriate for its actual target (embedded, on-device, multi-provider), while consciously dropping the parts of synapse-cortex that are genuinely server/product features rather than memory-engine features. As of the 2026-08-20 second-pass re-verification, entity resolution (previously the highest-priority gap) has a real deterministic fix in place, memory CRUD primitives exist for a host app to build a browse/edit UI on, and Notion export/import, Gemini context caching, and knowledge graph visualization are all implemented and tested (not the unbuilt gaps an earlier pass of this doc claimed). What's actually left: correction-targeting precision for subject-only facts (moderate priority, see above), and the genuinely-missing retrieval-quality features — automatic retrieval gating and reranking — neither of which requires a server, they're just not built yet.
