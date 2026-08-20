# AiPersona vs. synapse-cortex — Feature Comparison

Source: https://github.com/juandastic/synapse-cortex#core-features (reference project, server-side, Python/FastAPI/Neo4j/Graphiti). Compared against the README's 9 numbered Core Features 1:1.
Target: `AiPersona` (this package — Swift Package, on-device, SwiftData), reviewed at commit `5e49ce8` (2026-07-22).

Legend: ✅ Done · 🟡 Partial / simplified · ❌ Not implemented

## 0. Core Features (README, 1:1)

| # | synapse-cortex feature | AiPersona | Status |
|---|---|---|---|
| 1 | Knowledge Graph Ingestion (session processing, entity resolution, temporal awareness, degree-based filtering) | Session processing ✅, entity resolution 🟡 exact-match only, temporal awareness ✅, degree-based filtering ❌ | 🟡 Partial |
| 2 | OpenAI-Compatible Chat Completions (SSE streaming, Gemini backend, system-prompt injection) | Not a chat API by design — prompt-fragment builder only; Gemini backend ✅; system-prompt injection ✅ | ❌ Out of scope (chat API), ✅ Done (injection) |
| 3 | Smart Context Retrieval / Hydration (two-phase compilation, Cypher-optimized, connectivity-based ranking) | Single-phase fact-limit compilation, no connectivity/degree ranking | 🟡 Partial |
| 4 | GraphRAG per-turn retrieval (hybrid search + RRF, dedup, automatic gating, zero-LLM overhead) | ✅ Hybrid BM25+embedding RRF, ✅ dedup vs. compilation, ❌ no automatic gating (`is_partial` equivalent), ✅ deterministic no-agent-loop | 🟡 Mostly done |
| 5 | Gemini Context Caching (cached prefix, TTL refresh, size-gated, stateless) | ❌ None implemented | ❌ Not implemented |
| 6 | Knowledge Graph Visualization (React-Force-Graph node/link export, real-time corrections, temporal filtering) | ❌ No graph-export format; `allEntities()`/`allFacts()` return raw SwiftData models, not a nodes/links shape. Real-time corrections ✅ (via ingestion), temporal filtering ✅ (`activeFacts()`) | ❌ Not implemented (visualization-specific export) |
| 7 | Notion Export (graph→Notion pipeline, dynamic schema via Gemini, MCP agent, async+polling, feedback-loop columns, per-request auth) | ❌ None | ❌ Not implemented |
| 8 | Notion Correction Import (reads corrections from Notion, MCP agent row updates, `add_episode` w/ custom instructions, partial-failure handling) | ❌ None | ❌ Not implemented |
| 9 | Security & Rate Limiting (API key auth header, concurrency semaphore, CORS) | API key auth ✅ (Keychain, header-based per commit `8cd8b97`), concurrency limiting ❌ not applicable (no server), CORS ❌ N/A (no server) | 🟡 Partial (server-shaped items N/A by design) |

Note: the previous pass merged features 7+8 into a single "Notion" row and had no dedicated row for feature 6 — both corrected above.

## 1. Core Architecture

| Aspect | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Runtime | Stateless REST API (FastAPI/Uvicorn), Docker/Digital Ocean | In-process Swift library, embedded in a host app (macOS 14+/iOS 17+) | 🟡 Different deployment model by design |
| Storage | Neo4j graph DB + vector index | SwiftData (`EntityNode`, `EpisodicNode`, `FactEdge`) in an isolated on-disk store (`AiPersonaMemory.store`) | ✅ Equivalent graph shape, embedded engine |
| Graph engine | Graphiti Core (temporal KG library) | Hand-rolled equivalent (`MemoryGraphStore`) | ✅ Core semantics reproduced, not the library |
| Multi-tenant / multi-user | Yes — per-request auth, stateless cache-name ownership | No — single local user/persona per host app instance | ❌ Not applicable to on-device use case |

## 2. Knowledge Graph & Entities

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Entity nodes (people, places, concepts) | ✅ Graphiti `Entity` | ✅ `EntityNode` (`Sources/AiPersona/Memory/MemoryModels.swift:13`) | ✅ Done |
| Episodic nodes (raw conversation) | ✅ Graphiti `Episodic` | ✅ `EpisodicNode` (`MemoryModels.swift:39`) | ✅ Done |
| Relationship/fact edges | ✅ Graphiti edges with facts + timestamps | ✅ `FactEdge` (`MemoryModels.swift:55`) | ✅ Done |
| Temporal validity (`valid_at`/`invalid_at`) | ✅ | ✅ Same fields, same semantics — never deletes, only invalidates (`MemoryGraphStore.swift:76-120`) | ✅ Done |
| Entity resolution / dedup ("Juan", "JG" → one node) | ✅ LLM-driven fuzzy resolution via Graphiti | 🟡 Case-insensitive **exact name match only** (`findEntity`, `MemoryGraphStore.swift:58-61`) — explicitly documented as a simplification, no embedding-similarity fuzzy matching | 🟡 Partial |
| Degree-based / confidence-based entity ranking | ✅ Used in hydration to exclude low-confidence entities | ❌ No node-degree concept at all | ❌ Not implemented |
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
| Gemini context caching (~75% cost reduction) | ✅ Explicit cached-prefix management, stateless client-owned cache names | ❌ Not implemented — no caching layer over Gemini calls | ❌ Not implemented |
| Cost-aware retrieval budget | ✅ V2 hydration budget (~120k chars) | ❌ Fixed `factLimit`/`limit` integers, no token/character budget logic | ❌ Not implemented |

## 7. External Integrations

| Feature | synapse-cortex | AiPersona | Status |
|---|---|---|---|
| Notion Export (graph → Notion DBs, Gemini-designed dynamic schema, MCP agent, async+polling, feedback-loop columns) | ✅ Full pipeline via `create_react_agent` + Notion MCP server | ❌ No Notion, no MCP, no export pipeline | ❌ Not implemented |
| Notion Correction Import (reads corrections from Notion, MCP agent updates/deletes rows, `add_episode` w/ `custom_extraction_instructions`, partial-failure handling) | ✅ Full pipeline | ❌ None | ❌ Not implemented |
| Knowledge Graph Visualization (React-Force-Graph node/link export format, temporal filtering) | ✅ Dedicated endpoint returning nodes/links shaped for frontend rendering | ❌ No graph-export format at all — `allEntities()`/`allFacts()` (`MemoryGraphStore.swift:130-140`) return raw SwiftData models, not a nodes/links shape a UI could render directly | ❌ Not implemented |
| Any general UI for browsing/editing memory | ✅ Via Notion | ❌ None — headless library, host app would need to build its own UI over `MemoryGraphStore.allEntities()/allFacts()` | ❌ Not implemented |

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
| Entity resolution / dedup | 🟡 Partial (exact-match only, no fuzzy/LLM resolution) |
| Degree-based entity ranking | ❌ Not implemented |
| Hydration (session compilation) | 🟡 Partial (no character-budget strategy) |
| Per-turn GraphRAG-style retrieval | ✅ Done |
| BM25 + embedding hybrid search (RRF) | ✅ Done |
| Automatic retrieval gating (skip when compilation already covers the graph) | ❌ Not implemented |
| Reranking | ❌ Not implemented |
| Multi-provider LLM support | ✅ Done (exceeds source — source is Gemini-only) |
| System prompt injection | ✅ Done |
| Gemini context caching | ❌ Not implemented |
| Cost/budget-aware retrieval | ❌ Not implemented |
| Notion export | ❌ Not implemented |
| Notion correction import | ❌ Not implemented |
| Knowledge graph visualization (node/link export) | ❌ Not implemented |
| Chat completions API (server) | ❌ Out of scope (different product shape) |
| Memory browsing/editing UI (general) | ❌ Not implemented |
| Multi-tenant/stateless server model | ❌ Not applicable (on-device single-user design) |

---

## Detailed Review & Recommendations

**What this package actually is.** AiPersona is not a port of synapse-cortex — it's a from-scratch, on-device reimplementation of synapse-cortex's *cognitive core* (temporal knowledge graph + hybrid retrieval + LLM-driven extraction/correction), deliberately stripped of everything that only makes sense for a multi-tenant server product (Neo4j, Docker, Notion, a chat completions API, multi-tenant auth). That's the right scope decision for a Swift Package meant to be embedded in a host app — trying to reproduce the REST-API/Neo4j/Notion surface area would fight the target platform rather than serve it.

**Where the reimplementation is genuinely strong.** The temporal fact model (bi-temporal `validAt`/`invalidAt`, never-delete semantics), the BM25+embedding RRF hybrid search, and the two-layer retrieval split (cached session compilation + per-turn top-up excluding what's already surfaced) all mirror synapse-cortex's actual mechanics rather than just its vocabulary. The multi-provider abstraction (local MLX / Gemini / OpenAI / Anthropic, independently selectable for extraction vs. chat) is a real improvement over the source, which is hard-wired to Gemini. Code comments throughout show these design choices were made deliberately and validated against real bugs (e.g. the SwiftData store-collision fix, the persona preamble fix, the correction-targeting narrowing) — this is not vibe-coded; it reads as carefully reasoned.

**The two simplifications most likely to bite in practice, in order of impact:**

1. **Entity resolution is exact-match only.** `findEntity` does a case-insensitive string match — "Juan" and "Juan Gómez" become two separate nodes with no linkage. Synapse-cortex's whole reason for existing is *avoiding* this kind of graph fragmentation. As the fact count grows, this will silently degrade retrieval quality (duplicate/fragmented entities split the fact edges that should be associated with one node) without ever surfacing as an error. This is the highest-value gap to close — even a cheap embedding-similarity threshold before falling back to exact match would meaningfully help, and `LocalEmbedder` + `cosineSimilarity` already exist to do it with almost no new code.

2. **Correction invalidation for subject-only facts is a similarity threshold, not true resolution.** The current approach (invalidate the single most-similar active fact above `minimumSimilarity`, else no-op) is a reasonable, safety-first stopgap — it explicitly favors under-correcting over wrongly wiping unrelated facts — but it means some genuine corrections will silently fail to apply if similarity falls just under the bar, with no user-visible signal that the correction "did nothing." Worth deciding whether that failure mode should ever surface (e.g. a debug log, or returning a bool from `invalidateFacts` so a host app *could* choose to tell the user "I'm not sure what to update").

**Correction to an earlier pass of this review:** Notion export/import (features 7 & 8) and Gemini context caching (feature 5) were initially filed as "fine to leave out" on the assumption they require a server or MCP-agent runtime. That assumption doesn't hold. Both are plain REST APIs — `api.notion.com/v1` (bearer integration token) and `generativelanguage.googleapis.com/v1beta/cachedContents` (the same API key `GeminiProvider` already uses) — directly callable from an on-device Swift client. `MemorySettingsStore.swift:22-60` already has the exact Keychain-backed per-provider token pattern a Notion integration or a caching client would reuse. What synapse-cortex layers on top of the REST calls (Gemini-designed dynamic Notion schemas, an MCP `create_react_agent` for row creation) is an implementation choice, not a requirement — and actually cuts against AiPersona's own praised "deterministic, no agent loop" design. All three (Notion export, Notion import, Gemini caching) are now tracked as real, buildable gaps rather than out-of-scope items.

**Knowledge Graph Visualization (feature 6) deserves its own call-out, not a folded-in mention.** It's a distinct numbered core feature in the source — a dedicated node/link export shaped for `react-force-graph` rendering, with temporal filtering baked in. AiPersona has no equivalent export format at all: `allEntities()`/`allFacts()` return raw SwiftData models, not a UI-renderable graph shape. Like Notion and Gemini caching, this needs no server or agent — a pure function mapping `EntityNode`/`FactEdge` to a `{nodes, links}` JSON shape could ship as a lightweight addition.

**What's genuinely out of scope, re-checked individually rather than assumed:** the OpenAI-compatible *SSE server endpoint* specifically (feature 2 — requires listening for inbound HTTP requests, which an embedded library cannot do; the underlying chat-generation capability itself already exists via `ChatProvider`/`GeminiProvider.complete`), multi-tenant per-request auth (feature 9 — meaningless for a single-user library; one Keychain token per provider is the correct equivalent), and CORS (feature 9 — a browser cross-origin concept with no applicable surface here). Checked and ruled out as a gap, not just assumed away: concurrency-limiting against provider 429s (feature 9's semaphore) — `IngestionActor` is a Swift `actor`, so concurrent `enqueue` calls are already serialized by the language's actor isolation, achieving the same practical effect without an explicit limiter.

Degree-based entity ranking, automatic retrieval gating, and reranking (features 1 & 4) remain genuinely lower-priority — not because they're server-only, but because they matter more at graph/traffic scales this package isn't likely to reach on a personal device; worth revisiting if usage data says otherwise.

**One structural risk worth flagging, not a feature gap:** `MemoryGraphStore`, `RetrievalService`, `PersonaStore`, and `MemorySettingsStore` are all `@MainActor` singletons. That's fine for a small local dataset today, but `BM25Scorer`/`HybridSearch` recompute over the *entire* active-fact set on every call with no persistent index — documented as an intentional simplification ("future optimization if profiling ever shows otherwise"). Worth keeping an eye on once a host app's users accumulate thousands of facts; recomputing full BM25 on the main actor on every chat turn is the kind of thing that's invisible in testing and shows up as UI jank in the field.

**Overall assessment:** the package has faithfully captured synapse-cortex's core cognitive-loop *ideas* (temporal graph, hybrid retrieval, correction-via-invalidation, LLM-driven extraction) in an architecture appropriate for its actual target (embedded, on-device, multi-provider), while consciously dropping the parts of synapse-cortex that are genuinely server/product features rather than memory-engine features. The remaining gaps split into two groups: entity resolution quality (highest priority, cheap to fix) and four features with no client-side equivalent implemented yet but no architectural blocker either — Notion export, Notion correction import, Gemini caching, and knowledge graph visualization. None of those four require a server; they're unbuilt, not unbuildable.
