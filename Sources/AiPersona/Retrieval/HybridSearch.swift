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

/// Small, deliberately conservative stopword list — only words common enough to appear in nearly
/// any English sentence regardless of topic. Not meant to be linguistically complete; it exists
/// solely to keep `sharedContentTerms` from counting coincidental function-word overlap as
/// evidence of topical relevance.
private let contentWordStopwords: Set<String> = [
    "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "and", "or", "but",
    "if", "then", "of", "to", "in", "on", "for", "with", "by", "at", "from", "as", "that",
    "this", "these", "those", "it", "its", "should", "how", "what", "when", "where", "who",
    "which", "do", "does", "did", "not", "no", "you", "your", "i", "we", "they", "he", "she",
    "will", "can", "must", "may", "would", "could", "so", "than", "into", "about", "our",
]

private func contentTerms(_ text: String) -> Set<String> {
    Set(
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !contentWordStopwords.contains($0) }
    )
}

/// Fuses BM25 (Task 7) and embedding-similarity (Task 8) rankings via Reciprocal Rank Fusion —
/// mirrors Graphiti's `EDGE_HYBRID_SEARCH_RRF`/`NODE_HYBRID_SEARCH_RRF`.
public enum HybridSearch {
    public static func search(
        query: String, queryEmbedding: [Float], documents: [EmbeddedDocument], limit: Int, rrfK: Double = 60
    ) -> [UUID] {
        searchScored(query: query, queryEmbedding: queryEmbedding, documents: documents, limit: limit, rrfK: rrfK)
            .map(\.id)
    }

    public static func searchScored(
        query: String, queryEmbedding: [Float], documents: [EmbeddedDocument], limit: Int, rrfK: Double = 60
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

        let embeddingByID = Dictionary(uniqueKeysWithValues: documents.map {
            ($0.id, LocalEmbedder.cosineSimilarity(queryEmbedding, $0.embedding))
        })
        let embeddingRanked = documents
            .map { (id: $0.id, score: embeddingByID[$0.id] ?? 0) }
            .sorted { $0.score > $1.score }
            .map(\.id)

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
