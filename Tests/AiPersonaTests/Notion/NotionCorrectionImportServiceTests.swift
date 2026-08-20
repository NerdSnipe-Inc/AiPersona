import XCTest
@testable import AiPersona

private struct StubMemoryProvider: MemoryProvider {
    let facts: [ExtractedFact]
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { facts }
}

@MainActor
final class NotionCorrectionImportServiceTests: XCTestCase {

    func test_importCorrections_clearsNeedsReview_whenCorrectionSuccessfullyInvalidatesAFact() async throws {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))

        let client = StubNotionAPIClient()
        await client.setNeedsReviewRowsToReturn([
            NotionCorrectionRow(pageID: "page-1", subjectName: "User", correctionNotes: "no longer wants the O-1 visa")
        ])
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "no longer wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])

        let failedRows = try await NotionCorrectionImportService.importCorrections(
            client: client, provider: provider, store: store, databaseID: "db-1"
        )

        XCTAssertEqual(failedRows, [])
        let clearedIDs = await client.clearedNeedsReviewPageIDs
        XCTAssertEqual(clearedIDs, ["page-1"])
        XCTAssertEqual(store.activeFacts().count, 0)
    }

    func test_importCorrections_leavesNeedsReviewSet_whenCorrectionMatchesNothing() async throws {
        let store = MemoryGraphStore(inMemory: true)
        let client = StubNotionAPIClient()
        let row = NotionCorrectionRow(pageID: "page-2", subjectName: "User", correctionNotes: "no longer wants the O-1 visa")
        await client.setNeedsReviewRowsToReturn([row])
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "no longer wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])

        let failedRows = try await NotionCorrectionImportService.importCorrections(
            client: client, provider: provider, store: store, databaseID: "db-1"
        )

        XCTAssertEqual(failedRows, [row], "a correction that matched nothing should be surfaced, not silently cleared")
        let clearedIDs = await client.clearedNeedsReviewPageIDs
        XCTAssertEqual(clearedIDs, [])
    }
}
