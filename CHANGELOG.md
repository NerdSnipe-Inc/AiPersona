# Changelog

All notable changes to AiPersona are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
