import Foundation

/// A document with both raw text (for BM25) and a precomputed embedding (for cosine similarity).
public struct EmbeddedDocument {
    public let id: UUID
    public let text: String
    public let embedding: [Float]
    public init(id: UUID, text: String, embedding: [Float]) {
        self.id = id
        self.text = text
        self.embedding = embedding
    }
}

/// One RRF-ranked result plus underlying signals, so a caller can apply its own relevance floor
/// on top of the fused ranking — RRF only encodes relative rank, not whether the #1 result is
/// actually a good match, so a candidate pool that contains nothing relevant still returns its
/// least-bad members with no signal that they're weak. `sharedContentTerms` is deliberately not
/// the raw BM25 score: BM25's IDF gives even a shared stopword ("and", "the") a small nonzero
/// score, so "bm25Score > 0" doesn't reliably mean the match is about the same thing. This counts
/// only non-stopword term overlap — the cheapest signal that actually distinguishes "shares a
/// real word with the query" from "shares 'and'" — and is what caught the
/// email-deliverability-vs-document-delivery misfire in packs/ghl-core-v1/reviews/
/// live-swift-retrieval-results-2026-08-20/README.md.
public struct RankedResult {
    public let id: UUID
    public let bm25Score: Double
    public let embeddingSimilarity: Double
    public let sharedContentTerms: Int
}

/// Fuses BM25 (Task 7) and embedding-similarity (Task 8) rankings via Reciprocal Rank Fusion —
/// mirrors Graphiti's `EDGE_HYBRID_SEARCH_RRF`/`NODE_HYBRID_SEARCH_RRF`.
public enum HybridSearch {
    /// Below this fraction of a query's words resolving to an in-vocabulary embedding, the
    /// embedding signal is dropped from fusion entirely rather than down-weighted — see
    /// `queryEmbeddingCoverage`'s doc comment. Chosen so a query where the *majority* of its words
    /// are OOV (the "spf/dkim/dmarc/webhook/idempotency" case, all of which resolve to nothing)
    /// falls back to BM25-only, while a query that's mostly generic words plus one unresolved term
    /// still gets the benefit of the embedding signal.
    public static let minimumQueryEmbeddingCoverage = 0.5

    public static func search(
        query: String, queryEmbedding: [Float], documents: [EmbeddedDocument], limit: Int, rrfK: Double = 60,
        queryEmbeddingCoverage: Double = 1.0
    ) -> [UUID] {
        searchScored(
            query: query, queryEmbedding: queryEmbedding, documents: documents, limit: limit, rrfK: rrfK,
            queryEmbeddingCoverage: queryEmbeddingCoverage
        ).map(\.id)
    }

    /// `queryEmbeddingCoverage` is the fraction of `query`'s words that actually resolved to an
    /// in-vocabulary word vector (see `LocalEmbedder.embedWithCoverage`). Defaults to `1.0` so
    /// existing callers that don't pass it keep today's behavior unchanged. Below
    /// `minimumQueryEmbeddingCoverage`, the embedding ranking is excluded from RRF fusion and the
    /// result is BM25-only — proven directly (packs/ghl-core-v1/reviews/
    /// live-swift-retrieval-results-2026-08-20/README.md) that BM25 alone already ranks these
    /// OOV-heavy technical queries (e.g. SPF/DKIM/DMARC, webhook idempotency) correctly, while
    /// fusing in an embedding built from mostly-missing words drags the fused ranking toward
    /// whatever leftover generic word happened to resolve, actively burying the correct match.
    public static func searchScored(
        query: String, queryEmbedding: [Float], documents: [EmbeddedDocument], limit: Int, rrfK: Double = 60,
        queryEmbeddingCoverage: Double = 1.0
    ) -> [RankedResult] {
        guard !documents.isEmpty else { return [] }

        let queryContentTerms = contentTerms(query)
        let sharedContentTermsByID = Dictionary(uniqueKeysWithValues: documents.map {
            ($0.id, queryContentTerms.intersection(contentTerms($0.text)).count)
        })

        let bm25Documents = documents.map { BM25Document(id: $0.id, text: $0.text) }
        let bm25Results = BM25Scorer.score(query: query, documents: bm25Documents)
        let bm25ByID = Dictionary(uniqueKeysWithValues: bm25Results.map { ($0.id, $0.score) })
        let bm25Ranked = bm25Results.sorted { $0.score > $1.score }.map(\.id)

        let useEmbeddingSignal = queryEmbeddingCoverage >= minimumQueryEmbeddingCoverage
        let embeddingByID = Dictionary(uniqueKeysWithValues: documents.map {
            ($0.id, useEmbeddingSignal ? LocalEmbedder.cosineSimilarity(queryEmbedding, $0.embedding) : 0)
        })
        let embeddingRanked = useEmbeddingSignal
            ? documents
                .map { (id: $0.id, score: embeddingByID[$0.id] ?? 0) }
                .sorted { $0.score > $1.score }
                .map(\.id)
            : []

        var rrfScores: [UUID: Double] = [:]
        for (rank, id) in bm25Ranked.enumerated() {
            rrfScores[id, default: 0] += 1 / (rrfK + Double(rank + 1))
        }
        for (rank, id) in embeddingRanked.enumerated() {
            rrfScores[id, default: 0] += 1 / (rrfK + Double(rank + 1))
        }

        return rrfScores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map {
                RankedResult(
                    id: $0.key,
                    bm25Score: bm25ByID[$0.key] ?? 0,
                    embeddingSimilarity: embeddingByID[$0.key] ?? 0,
                    sharedContentTerms: sharedContentTermsByID[$0.key] ?? 0
                )
            }
    }
}
