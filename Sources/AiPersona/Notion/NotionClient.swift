import Foundation

enum NotionClientError: Error, Sendable {
    case invalidResponse
}

/// Abstraction over the Notion network calls `NotionExportService`/`NotionCorrectionImportService`
/// need, so their orchestration/branching logic (what to do on success vs. failure) is testable
/// with a stub instead of requiring network access — `NotionClient` is the real implementation.
public protocol NotionAPIClient: Sendable {
    func createDatabase(parentPageID: String) async throws -> String
    func createPage(databaseID: String, row: NotionExportRow) async throws
    func queryNeedsReview(databaseID: String) async throws -> [NotionCorrectionRow]
    func clearNeedsReview(pageID: String) async throws
}

/// Direct REST calls against `api.notion.com/v1` — no MCP agent, no server. Authenticated with a
/// bearer integration token sent as a header, exactly like `GeminiProvider` sends its API key as
/// a header (never the URL). Request-building and response-parsing are pure/testable, matching
/// this codebase's existing `GeminiProvider` convention; the network-calling methods that
/// actually invoke `URLSession` are thin wrappers over those, same as `GeminiProvider.complete`.
public struct NotionClient: NotionAPIClient, Sendable {
    private static let baseURL = "https://api.notion.com/v1"
    private static let apiVersion = "2022-06-28"

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    private func baseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        return request
    }

    // MARK: - Request building

    func buildCreateDatabaseRequest(parentPageID: String) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/databases")!, method: "POST")
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentPageID],
            "title": [["type": "text", "text": ["content": "AiPersona Memory"]]],
            "properties": [
                "Name": ["title": [String: Any]()],
                "Kind": ["rich_text": [String: Any]()],
                "Fact": ["rich_text": [String: Any]()],
                "Valid From": ["date": [String: Any]()],
                "Needs Review": ["checkbox": [String: Any]()],
                "Correction Notes": ["rich_text": [String: Any]()]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func buildCreatePageRequest(databaseID: String, row: NotionExportRow) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/pages")!, method: "POST")
        let isoDate = ISO8601DateFormatter().string(from: row.validFrom)
        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": [
                "Name": ["title": [["text": ["content": row.subjectName]]]],
                "Kind": ["rich_text": [["text": ["content": row.kind]]]],
                "Fact": ["rich_text": [["text": ["content": row.factText]]]],
                "Valid From": ["date": ["start": isoDate]],
                "Needs Review": ["checkbox": row.needsReview],
                "Correction Notes": ["rich_text": [["text": ["content": row.correctionNotes]]]]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func buildQueryNeedsReviewRequest(databaseID: String) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/databases/\(databaseID)/query")!, method: "POST")
        let body: [String: Any] = [
            "filter": ["property": "Needs Review", "checkbox": ["equals": true]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func buildClearNeedsReviewRequest(pageID: String) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/pages/\(pageID)")!, method: "PATCH")
        let body: [String: Any] = ["properties": ["Needs Review": ["checkbox": false]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response parsing

    static func parseID(fromResponseBody data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["id"] as? String
    }

    static func parseCorrectionRows(fromResponseBody data: Data) -> [NotionCorrectionRow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { result -> NotionCorrectionRow? in
            guard let pageID = result["id"] as? String,
                  let properties = result["properties"] as? [String: Any]
            else { return nil }

            let name = plainText(fromTitleProperty: properties["Name"])
            let notes = plainText(fromRichTextProperty: properties["Correction Notes"])
            return NotionCorrectionRow(pageID: pageID, subjectName: name, correctionNotes: notes)
        }
    }

    private static func plainText(fromTitleProperty property: Any?) -> String {
        guard let dict = property as? [String: Any], let title = dict["title"] as? [[String: Any]] else { return "" }
        return title.compactMap { $0["plain_text"] as? String }.joined()
    }

    private static func plainText(fromRichTextProperty property: Any?) -> String {
        guard let dict = property as? [String: Any], let richText = dict["rich_text"] as? [[String: Any]] else { return "" }
        return richText.compactMap { $0["plain_text"] as? String }.joined()
    }

    // MARK: - Network calls

    public func createDatabase(parentPageID: String) async throws -> String {
        let request = try buildCreateDatabaseRequest(parentPageID: parentPageID)
        let (data, _) = try await session.data(for: request)
        guard let id = Self.parseID(fromResponseBody: data) else { throw NotionClientError.invalidResponse }
        return id
    }

    public func createPage(databaseID: String, row: NotionExportRow) async throws {
        let request = try buildCreatePageRequest(databaseID: databaseID, row: row)
        _ = try await session.data(for: request)
    }

    public func queryNeedsReview(databaseID: String) async throws -> [NotionCorrectionRow] {
        let request = try buildQueryNeedsReviewRequest(databaseID: databaseID)
        let (data, _) = try await session.data(for: request)
        return Self.parseCorrectionRows(fromResponseBody: data)
    }

    public func clearNeedsReview(pageID: String) async throws {
        let request = try buildClearNeedsReviewRequest(pageID: pageID)
        _ = try await session.data(for: request)
    }
}
