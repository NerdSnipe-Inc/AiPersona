import XCTest
@testable import AiPersona

final class GeminiCacheClientTests: XCTestCase {

    func test_buildCreateCacheRequest_targetsCachedContentsEndpoint_withAPIKeyInHeaderNotURL() throws {
        let client = GeminiCacheClient(apiKey: "test-key")
        let request = try client.buildCreateCacheRequest(model: "gemini-2.5-flash", systemPrompt: "some long compilation text", ttlSeconds: 3600)

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(url, "https://generativelanguage.googleapis.com/v1beta/cachedContents")
        XCTAssertFalse(url.contains("test-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "models/gemini-2.5-flash")
        XCTAssertEqual(json["ttl"] as? String, "3600s")
        let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let parts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "some long compilation text")
    }

    func test_buildRefreshTTLRequest_targetsCacheNameEndpoint_withPatchMethod() throws {
        let client = GeminiCacheClient(apiKey: "test-key")
        let request = try client.buildRefreshTTLRequest(cacheName: "cachedContents/abc123", ttlSeconds: 3600)

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/cachedContents/abc123")
        XCTAssertEqual(request.httpMethod, "PATCH")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["ttl"] as? String, "3600s")
    }

    func test_parseCacheName_extractsNameFromResponseBody() {
        let responseJSON = #"{"name": "cachedContents/abc123", "model": "models/gemini-2.5-flash"}"#.data(using: .utf8)!
        XCTAssertEqual(GeminiCacheClient.parseCacheName(fromResponseBody: responseJSON), "cachedContents/abc123")
    }

    func test_parseCacheName_returnsNil_forMalformedBody() {
        let responseJSON = #"{"error": "not found"}"#.data(using: .utf8)!
        XCTAssertNil(GeminiCacheClient.parseCacheName(fromResponseBody: responseJSON))
    }
}
