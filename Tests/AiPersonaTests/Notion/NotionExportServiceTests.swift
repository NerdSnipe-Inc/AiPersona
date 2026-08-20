import XCTest
@testable import AiPersona

@MainActor
final class NotionExportServiceTests: XCTestCase {

    func test_export_createsDatabaseUnderParentPage_thenOnePagePerActiveFact() async throws {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: [])
        let client = StubNotionAPIClient()

        let databaseID = try await NotionExportService.export(store: store, client: client, parentPageID: "parent-page")

        XCTAssertEqual(databaseID, "db-1")
        let parentPageID = await client.createdDatabaseParentPageID
        XCTAssertEqual(parentPageID, "parent-page")
        let createdPages = await client.createdPages
        XCTAssertEqual(createdPages.count, 1)
        XCTAssertEqual(createdPages[0].row.factText, "wants the O-1 visa")
    }

    func test_rows_mapsActiveFact_toRowWithSubjectNameAndKind() {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let validAt = Date()
        let fact = FactEdge(
            subjectID: user.id, objectID: nil, predicate: "wants",
            factText: "wants the O-1 visa", embedding: [], validAt: validAt
        )

        let rows = NotionExportService.rows(fromEntities: [user], activeFacts: [fact])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].subjectName, "User")
        XCTAssertEqual(rows[0].kind, "user")
        XCTAssertEqual(rows[0].factText, "wants the O-1 visa")
        XCTAssertEqual(rows[0].validFrom, validAt)
        XCTAssertFalse(rows[0].needsReview)
        XCTAssertEqual(rows[0].correctionNotes, "")
    }

    func test_rows_skipsFact_whenSubjectEntityIsMissing() {
        let orphanFact = FactEdge(
            subjectID: UUID(), objectID: nil, predicate: "wants",
            factText: "an orphaned fact", embedding: [], validAt: Date()
        )

        let rows = NotionExportService.rows(fromEntities: [], activeFacts: [orphanFact])

        XCTAssertEqual(rows, [])
    }

    func test_rows_mapsMultipleActiveFacts_inOrder() {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let factA = FactEdge(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: [], validAt: Date())
        let factB = FactEdge(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: [], validAt: Date())

        let rows = NotionExportService.rows(fromEntities: [user], activeFacts: [factA, factB])

        XCTAssertEqual(rows.map(\.factText), ["prefers dark mode", "wants the O-1 visa"])
    }
}
