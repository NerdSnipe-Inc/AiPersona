import XCTest
@testable import AiPersona

final class HybridSearchTests: XCTestCase {

    func test_search_ranksDocumentStrongInBothSignals_first() {
        let strongID = UUID()
        let bm25OnlyID = UUID()
        let embeddingOnlyID = UUID()

        let queryText = "concise replies"
        let queryEmbedding = LocalEmbedder.embed(queryText)

        let documents = [
            EmbeddedDocument(id: strongID, text: "user prefers concise replies", embedding: LocalEmbedder.embed("user prefers concise replies")),
            EmbeddedDocument(id: bm25OnlyID, text: "concise replies concise replies", embedding: LocalEmbedder.embed("completely unrelated sentence")),
            EmbeddedDocument(id: embeddingOnlyID, text: "totally different words here", embedding: LocalEmbedder.embed("short terse answers preferred")),
        ]

        let ranked = HybridSearch.search(query: queryText, queryEmbedding: queryEmbedding, documents: documents, limit: 3)

        XCTAssertEqual(ranked.first, strongID)
    }

    func test_search_respectsLimit() {
        let documents = (0..<10).map { i in
            EmbeddedDocument(id: UUID(), text: "document number \(i)", embedding: LocalEmbedder.embed("document number \(i)"))
        }
        let ranked = HybridSearch.search(query: "document", queryEmbedding: LocalEmbedder.embed("document"), documents: documents, limit: 3)

        XCTAssertEqual(ranked.count, 3)
    }

    func test_search_emptyDocuments_returnsEmpty() {
        XCTAssertTrue(HybridSearch.search(query: "anything", queryEmbedding: [], documents: [], limit: 5).isEmpty)
    }

    func test_searchScored_lowQueryEmbeddingCoverage_excludesEmbeddingSignal_matchesBM25OnlyOrder() {
        // Reproduces the root cause in packs/ghl-core-v1/reviews/finish-knowledge-base.md: when a
        // query's embedding is built from mostly out-of-vocabulary words, a misleading embedding
        // can distort the fused ranking. `bm25WinnerID` has the literal query terms and wins on
        // BM25 alone; its embedding is fabricated to be an exact cosine match for the query — the
        // strongest possible embedding signal — so if that signal leaked into fusion despite low
        // coverage, the fused order would trivially agree anyway and the test would prove nothing.
        // Below the coverage threshold, fusion must exclude the embedding signal entirely: both the
        // fused order AND every result's reported `embeddingSimilarity` must match plain BM25.
        let bm25WinnerID = UUID()
        let bm25LoserID = UUID()

        let queryText = "webhook idempotency handling requires a dedupe key"
        let queryEmbedding: [Float] = [1, 0, 0]

        let documents = [
            EmbeddedDocument(id: bm25LoserID, text: "totally unrelated document about something else entirely", embedding: [1, 0, 0]),
            EmbeddedDocument(id: bm25WinnerID, text: queryText, embedding: [1, 0, 0]),
        ]

        let bm25OnlyOrder = BM25Scorer.score(
            query: queryText, documents: documents.map { BM25Document(id: $0.id, text: $0.text) }
        ).sorted { $0.score > $1.score }.map(\.id)

        let lowCoverageRanked = HybridSearch.searchScored(
            query: queryText, queryEmbedding: queryEmbedding, documents: documents, limit: 2,
            queryEmbeddingCoverage: 0
        )

        XCTAssertEqual(lowCoverageRanked.map(\.id), bm25OnlyOrder, "low coverage must fall back to exactly the BM25-only order")
        XCTAssertTrue(lowCoverageRanked.allSatisfy { $0.embeddingSimilarity == 0 }, "low coverage must exclude the embedding signal even though the fabricated embeddings are an exact cosine match")

        let fullCoverageRanked = HybridSearch.searchScored(
            query: queryText, queryEmbedding: queryEmbedding, documents: documents, limit: 2,
            queryEmbeddingCoverage: 1.0
        )
        XCTAssertTrue(fullCoverageRanked.contains { $0.embeddingSimilarity > 0 }, "sanity check: full coverage must actually compute the embedding signal, proving the exclusion above is doing something")
    }

    func test_searchScored_defaultCoverage_preservesExistingBehavior() {
        // No existing caller passes queryEmbeddingCoverage yet outside RetrievalService — the
        // default must keep behaving as if coverage were always full, so this change is a pure
        // opt-in add for callers that don't ask for the fallback.
        let strongID = UUID()
        let queryText = "concise replies"
        let queryEmbedding = LocalEmbedder.embed(queryText)
        let documents = [
            EmbeddedDocument(id: strongID, text: "user prefers concise replies", embedding: LocalEmbedder.embed("user prefers concise replies")),
            EmbeddedDocument(id: UUID(), text: "totally different words here", embedding: LocalEmbedder.embed("totally different words here")),
        ]

        let ranked = HybridSearch.searchScored(query: queryText, queryEmbedding: queryEmbedding, documents: documents, limit: 2)

        XCTAssertEqual(ranked.first?.id, strongID)
    }
}
