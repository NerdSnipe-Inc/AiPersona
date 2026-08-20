import Foundation

enum GeminiCacheClientError: Error, Sendable {
    case invalidResponse
}

/// Abstraction over the Gemini cache network calls `GeminiContextCacheService` needs, so its
/// size-gating/reuse orchestration is testable with a stub instead of requiring network access —
/// `GeminiCacheClient` is the real implementation. Mirrors `NotionAPIClient`'s role for Notion.
public protocol GeminiCacheAPIClient: Sendable {
    func createCache(model: String, systemPrompt: String, ttlSeconds: Int) async throws -> String
    func refreshTTL(cacheName: String, ttlSeconds: Int) async throws
}

/// Direct REST calls against Gemini's `cachedContents` resource
/// (`generativelanguage.googleapis.com/v1beta/cachedContents`) — the same host and API key
/// `GeminiProvider` already uses, authenticated via header (never the URL), same as
/// `GeminiProvider` — a plain REST call, needs no server.
public struct GeminiCacheClient: GeminiCacheAPIClient, Sendable {
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private func baseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    // MARK: - Request building

    func buildCreateCacheRequest(model: String, systemPrompt: String, ttlSeconds: Int) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/cachedContents")!, method: "POST")
        let body: [String: Any] = [
            "model": "models/\(model)",
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "ttl": "\(ttlSeconds)s"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func buildRefreshTTLRequest(cacheName: String, ttlSeconds: Int) throws -> URLRequest {
        var request = baseRequest(url: URL(string: "\(Self.baseURL)/\(cacheName)")!, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ttl": "\(ttlSeconds)s"])
        return request
    }

    // MARK: - Response parsing

    static func parseCacheName(fromResponseBody data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    // MARK: - Network calls

    public func createCache(model: String, systemPrompt: String, ttlSeconds: Int) async throws -> String {
        let request = try buildCreateCacheRequest(model: model, systemPrompt: systemPrompt, ttlSeconds: ttlSeconds)
        let (data, _) = try await session.data(for: request)
        guard let name = Self.parseCacheName(fromResponseBody: data) else { throw GeminiCacheClientError.invalidResponse }
        return name
    }

    public func refreshTTL(cacheName: String, ttlSeconds: Int) async throws {
        let request = try buildRefreshTTLRequest(cacheName: cacheName, ttlSeconds: ttlSeconds)
        _ = try await session.data(for: request)
    }
}
