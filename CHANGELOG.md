# Changelog

All notable changes to AiPersona are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `FactEdge.isUserEdited` (defaults `false`, both at the property and `init` level, so an existing
  on-disk store migrates safely): set once a human hand-authors or hand-edits a fact — via the new
  `MemoryGraphStore.addFact(isUserEdited:)` parameter, or automatically by `updateFact`, which now
  sets `isUserEdited = true` as a side effect of any edit. There is no API that clears it back to
  `false`.
- `MemoryGraphStore.correctionCandidate(subjectID:relatedTo:minimumSimilarity:)`: read-only,
  cosine-similarity-scored lookup of the single best-match active fact for a subject-only
  correction, without mutating anything. `correctionCandidates(subjectID:objectID:)`: read-only
  lookup of EVERY active fact matching an exact subject+object pair. Both let a caller (in
  particular `IngestionActor.enqueue`) inspect a correction's match — especially whether it's
  `isUserEdited` — before deciding whether to invalidate it. `invalidateFacts(subjectID:objectID:
  relatedTo:...)` now delegates to these instead of duplicating their matching logic.
- `IngestionActor.EnqueueResult.pendingReviewCorrections: [PendingCorrection]`: corrections that
  matched an active fact protected by `isUserEdited`. `enqueue` no longer invalidates such a fact
  automatically — each `PendingCorrection` pairs the proposed `ExtractedFact` with the live
  `existingFact` so a host app can ask the user to Accept or Discard. `EnqueueResult` also gained
  `needsHumanReview: Bool`, true when either `failedCorrections` or `pendingReviewCorrections` is
  non-empty — prefer this over spelling out the conjunction inline.

### Changed
- **Source-breaking:** `IngestionActor.enqueue(...)` now returns `EnqueueResult` instead of
  `[ExtractedFact]`. Existing callers that captured the old return value (the list of failed
  corrections) must switch to `result.failedCorrections`; `NotionCorrectionImportService` and the
  README have been updated as the reference migration.
- `IngestionActor.enqueue`'s object-scoped correction handling (`objectName` set) now matches and
  acts on the WHOLE set of active facts sharing that subject+object, not a single arbitrary match:
  if any fact in the set is `isUserEdited`, none are invalidated and all are reported via
  `pendingReviewCorrections`; otherwise all are invalidated. This restores the pre-`isUserEdited`
  behavior of invalidating every matching fact (a prior in-progress version of this feature
  regressed to invalidating only one, nondeterministically, when several facts matched).

### Fixed
- `RetrievalService.excludedPredicates` (new, settable post-construction): predicates a host app
  reserves exclusively for `predicateScopedBlock` are now excluded from
  `sessionCompilation()`/`perTurnMemoryBlock()`'s general candidate pool. `EntityDegreeRanking`
  ranks by how many active facts share a subject, and a static reference fact set (all sharing one
  subject entity) has a degree an order of magnitude higher than any real, organically-grown
  contact could plausibly reach. Verified live against a real production store: the reference
  entity had degree 208 vs. the most-connected real contact's 22 — without this exclusion,
  `sessionCompilation()`'s budget was being filled entirely by reference facts, and real
  per-contact memory could never win a slot. `perTurnMemoryBlock` had the same unscoped pool, with
  no lexical-overlap floor to catch a bad match either.

### Added
- `RetrievalService.contactScopedBlock(forQuery:subjectIDs:limit:)`: hybrid search scoped to an
  explicit set of subject entity IDs, for a host app that has already identified which entity/
  entities the current query is about (e.g. a name mention) — instead of ranking across every
  entity's facts pooled together, which could surface an unrelated entity's fact just because it
  ranked higher. Returns `nil` for an empty ID set rather than falling back to a graph-wide search.
  Respects `excludedPredicates`.

## [1.0.4] - 2026-08-22

### Added
- OOV-aware embedding fallback for hybrid retrieval. `LocalEmbedder.embedWithCoverage(_:)` reports
  what fraction of a query's *content* words (non-stopword) actually resolved to an in-vocabulary
  `NLEmbedding` vector. `HybridSearch.searchScored` gained `queryEmbeddingCoverage` (default `1.0`,
  fully backward compatible) — below `HybridSearch.minimumQueryEmbeddingCoverage` (0.5), the
  embedding ranking is excluded from RRF fusion entirely, falling back to BM25-only ranking.
  `RetrievalService` now computes and passes real coverage for every query automatically.
- `Sources/AiPersona/Retrieval/ContentWords.swift`: content-word/stopword logic shared between
  `HybridSearch`'s existing lexical-overlap floor and the new embedding-coverage measurement.

### Fixed
- Retrieval no longer buries a correct BM25 match behind an irrelevant document when a query's
  embedding is built mostly from out-of-vocabulary words (e.g. domain jargon such as "webhook",
  "idempotency", "SPF", "DKIM", "DMARC" — verified to have no `NLEmbedding` vector at all). Root
  cause and fix validated against a real 208-fact production knowledge base; see the consuming
  app's `packs/ghl-core-v1/reviews/finish-knowledge-base.md` and
  `knowledge-base-retrieval-ships-2026-08-22.md` for the full investigation and live A/B results
  (98.3% pass rate with retrieval vs. 78–80% without, on a 60-case gate, across two independent
  runs).
- Coverage must be measured over content words only, not all words in the query — an earlier
  attempt measuring over every word stayed misleadingly high for short queries dominated by
  stopwords ("how", "should", "be"), masking exactly the OOV case this fix targets.

## [1.0.3] - 2026-08-20

### Fixed
- Stopped treating a SwiftPM checkout's sibling folder as a monorepo dev setup.

## [1.0.2] - 2026-08-20

### Fixed
- Bumped the `AIChatKitMLX` minimum version constraint to 1.0.0.

## [1.0.1] - 2026-08-20

### Changed
- Re-verified `source-compared.md` against current code; no functional changes.

## [1.0.0] - 2026-08-20

### Added
- Initial release: on-device, bi-temporal memory graph for AI chat apps — entity/fact graph store,
  BM25 + word-embedding hybrid search fused via Reciprocal Rank Fusion, session compilation ranked
  by entity degree, opt-in LLM reranking, and gated per-turn retrieval.
