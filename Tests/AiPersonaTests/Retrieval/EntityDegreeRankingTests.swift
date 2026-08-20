import XCTest
@testable import AiPersona

final class EntityDegreeRankingTests: XCTestCase {

    func test_degrees_countsSubjectAndObjectOccurrences() {
        let alice = UUID()
        let bob = UUID()
        let carol = UUID()
        let facts = [
            FactEdge(subjectID: alice, objectID: bob, predicate: "knows", factText: "Alice knows Bob", embedding: [], validAt: Date()),
            FactEdge(subjectID: alice, objectID: carol, predicate: "knows", factText: "Alice knows Carol", embedding: [], validAt: Date()),
            FactEdge(subjectID: bob, objectID: nil, predicate: "likes", factText: "Bob likes tea", embedding: [], validAt: Date()),
        ]

        let degrees = EntityDegreeRanking.degrees(forActiveFacts: facts)

        XCTAssertEqual(degrees[alice], 2, "Alice is subject of two facts")
        XCTAssertEqual(degrees[bob], 2, "Bob is object of one fact and subject of another")
        XCTAssertEqual(degrees[carol], 1, "Carol is object of one fact")
    }

    func test_rank_ordersByDegreeDescending_thenRecencyDescending() {
        let wellConnected = UUID()
        let lonely = UUID()
        let now = Date()

        let oldFactFromWellConnected = FactEdge(
            subjectID: wellConnected, objectID: nil, predicate: "has", factText: "old but well-connected",
            embedding: [], validAt: now.addingTimeInterval(-1000)
        )
        let newFactFromLonely = FactEdge(
            subjectID: lonely, objectID: nil, predicate: "has", factText: "new but lonely",
            embedding: [], validAt: now
        )
        let degrees: [UUID: Int] = [wellConnected: 5, lonely: 1]

        let ranked = EntityDegreeRanking.rank([newFactFromLonely, oldFactFromWellConnected], byDegrees: degrees)

        XCTAssertEqual(ranked.first?.factText, "old but well-connected", "higher subject degree should outrank a more recent, lower-degree fact")
    }

    func test_rank_breaksTiesByRecency_whenDegreesEqual() {
        let subject = UUID()
        let now = Date()
        let older = FactEdge(subjectID: subject, objectID: nil, predicate: "has", factText: "older", embedding: [], validAt: now.addingTimeInterval(-100))
        let newer = FactEdge(subjectID: subject, objectID: nil, predicate: "has", factText: "newer", embedding: [], validAt: now)
        let degrees: [UUID: Int] = [subject: 3]

        let ranked = EntityDegreeRanking.rank([older, newer], byDegrees: degrees)

        XCTAssertEqual(ranked.map(\.factText), ["newer", "older"], "equal degree should fall back to recency, matching prior sessionCompilation behavior")
    }
}
