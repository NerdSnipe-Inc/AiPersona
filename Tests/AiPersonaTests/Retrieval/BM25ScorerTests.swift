import XCTest
@testable import AiPersona

final class BM25ScorerTests: XCTestCase {

    func test_score_ranksExactTermMatchHigherThanUnrelatedDocument() {
        let matchID = UUID()
        let unrelatedID = UUID()
        let documents = [
            BM25Document(id: matchID, text: "user prefers concise replies over long ones"),
            BM25Document(id: unrelatedID, text: "the weather today is sunny and warm"),
        ]

        let results = BM25Scorer.score(query: "concise replies", documents: documents)
        let sorted = results.sorted { $0.score > $1.score }

        XCTAssertEqual(sorted.first?.id, matchID)
        XCTAssertGreaterThan(sorted[0].score, sorted[1].score)
    }

    func test_score_returnsZero_forEveryDocument_whenQueryHasNoOverlap() {
        let documents = [BM25Document(id: UUID(), text: "alpha beta gamma")]
        let results = BM25Scorer.score(query: "zzz nonexistent term", documents: documents)

        XCTAssertEqual(results.first?.score, 0)
    }

    func test_score_emptyDocumentSet_returnsEmpty() {
        XCTAssertTrue(BM25Scorer.score(query: "anything", documents: []).isEmpty)
    }
}
