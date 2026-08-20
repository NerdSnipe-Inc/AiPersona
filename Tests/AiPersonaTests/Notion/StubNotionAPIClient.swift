@testable import AiPersona

actor StubNotionAPIClient: NotionAPIClient {
    let databaseIDToReturn: String
    private(set) var createdDatabaseParentPageID: String?
    private(set) var createdPages: [(databaseID: String, row: NotionExportRow)] = []
    var needsReviewRowsToReturn: [NotionCorrectionRow] = []
    private(set) var clearedNeedsReviewPageIDs: [String] = []

    init(databaseIDToReturn: String = "db-1") {
        self.databaseIDToReturn = databaseIDToReturn
    }

    func createDatabase(parentPageID: String) async throws -> String {
        createdDatabaseParentPageID = parentPageID
        return databaseIDToReturn
    }

    func createPage(databaseID: String, row: NotionExportRow) async throws {
        createdPages.append((databaseID, row))
    }

    func setNeedsReviewRowsToReturn(_ rows: [NotionCorrectionRow]) {
        needsReviewRowsToReturn = rows
    }

    func queryNeedsReview(databaseID: String) async throws -> [NotionCorrectionRow] {
        needsReviewRowsToReturn
    }

    func clearNeedsReview(pageID: String) async throws {
        clearedNeedsReviewPageIDs.append(pageID)
    }
}
