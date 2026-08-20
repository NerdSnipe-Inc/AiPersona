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
}
