import XCTest
@testable import AiPersona

final class NotionClientTests: XCTestCase {

    // MARK: - Request building

    func test_buildCreateDatabaseRequest_targetsDatabasesEndpoint_withAuthHeaderNotURL() throws {
        let client = NotionClient(token: "secret_test_token")
        let request = try client.buildCreateDatabaseRequest(parentPageID: "page-123")

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(url, "https://api.notion.com/v1/databases")
        XCTAssertFalse(url.contains("secret_test_token"), "token must not appear in the URL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret_test_token")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parent = try XCTUnwrap(json["parent"] as? [String: Any])
        XCTAssertEqual(parent["page_id"] as? String, "page-123")
        XCTAssertNotNil(json["properties"])
    }

    func test_buildCreatePageRequest_encodesRowProperties() throws {
        let client = NotionClient(token: "secret_test_token")
        let row = NotionExportRow(subjectName: "User", kind: "user", factText: "wants the O-1 visa", validFrom: Date(timeIntervalSince1970: 0))
        let request = try client.buildCreatePageRequest(databaseID: "db-1", row: row)

        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parent = try XCTUnwrap(json["parent"] as? [String: Any])
        XCTAssertEqual(parent["database_id"] as? String, "db-1")

        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        let name = try XCTUnwrap(properties["Name"] as? [String: Any])
        let titleArray = try XCTUnwrap(name["title"] as? [[String: Any]])
        let titleText = try XCTUnwrap((titleArray.first?["text"] as? [String: Any])?["content"] as? String)
        XCTAssertEqual(titleText, "User")
    }

    func test_buildQueryNeedsReviewRequest_filtersOnCheckboxColumn() throws {
        let client = NotionClient(token: "secret_test_token")
        let request = try client.buildQueryNeedsReviewRequest(databaseID: "db-1")

        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/databases/db-1/query")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let filter = try XCTUnwrap(json["filter"] as? [String: Any])
        XCTAssertEqual(filter["property"] as? String, "Needs Review")
    }

    func test_buildClearNeedsReviewRequest_targetsPagePatchEndpoint() throws {
        let client = NotionClient(token: "secret_test_token")
        let request = try client.buildClearNeedsReviewRequest(pageID: "page-99")

        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/pages/page-99")
        XCTAssertEqual(request.httpMethod, "PATCH")
    }

    // MARK: - Response parsing

    func test_parseID_extractsIDFromResponseBody() {
        let responseJSON = #"{"id": "db-abc-123", "object": "database"}"#.data(using: .utf8)!
        XCTAssertEqual(NotionClient.parseID(fromResponseBody: responseJSON), "db-abc-123")
    }

    func test_parseID_returnsNil_forMalformedBody() {
        let responseJSON = #"{"object": "error"}"#.data(using: .utf8)!
        XCTAssertNil(NotionClient.parseID(fromResponseBody: responseJSON))
    }

    func test_parseCorrectionRows_extractsPageIDNameAndNotes() {
        let responseJSON = """
        {"results": [
            {"id": "page-1", "properties": {
                "Name": {"title": [{"plain_text": "User"}]},
                "Correction Notes": {"rich_text": [{"plain_text": "no longer wants the O-1 visa"}]}
            }}
        ]}
        """.data(using: .utf8)!

        let rows = NotionClient.parseCorrectionRows(fromResponseBody: responseJSON)

        XCTAssertEqual(rows, [NotionCorrectionRow(pageID: "page-1", subjectName: "User", correctionNotes: "no longer wants the O-1 visa")])
    }

    func test_parseCorrectionRows_returnsEmpty_whenResultsIsMissing() {
        let responseJSON = #"{"object": "error"}"#.data(using: .utf8)!
        XCTAssertEqual(NotionClient.parseCorrectionRows(fromResponseBody: responseJSON), [])
    }
}
