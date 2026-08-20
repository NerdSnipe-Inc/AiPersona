import XCTest
@testable import AiPersona
import AIChatCore

final class GeminiProviderTests: XCTestCase {

    func test_buildRequest_includesModelInURL_andAPIKeyInHeader_notURL() throws {
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.5-flash")
        let request = try provider.buildRequest(
            messages: [ChatMessage(role: .user, content: "hello")],
            options: ChatRequestOptions(systemPrompt: "Be helpful.")
        )

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("gemini-2.5-flash"))
        XCTAssertFalse(url.contains("test-key"), "API key must not appear in the URL — risks exposure via logging")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func test_buildRequest_encodesSystemPromptAndUserMessage() throws {
        let provider = GeminiProvider(apiKey: "test-key")
        let request = try provider.buildRequest(
            messages: [ChatMessage(role: .user, content: "what's the weather?")],
            options: ChatRequestOptions(systemPrompt: "Be terse.")
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["systemInstruction"])
        XCTAssertNotNil(json["contents"])
    }

    func test_buildRequest_withCachedContentName_referencesCache_insteadOfInliningSystemPrompt() throws {
        let provider = GeminiProvider(apiKey: "test-key")
        let request = try provider.buildRequest(
            messages: [ChatMessage(role: .user, content: "what's the weather?")],
            options: ChatRequestOptions(systemPrompt: "Be terse."),
            cachedContentName: "cachedContents/abc123"
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["cachedContent"] as? String, "cachedContents/abc123")
        XCTAssertNil(json["systemInstruction"], "the system prompt is already baked into the cache")
        XCTAssertNotNil(json["contents"], "the new turn's message still needs to be sent")
    }

    func test_parseResponse_extractsTextFromCandidates() throws {
        let responseJSON = """
        {"candidates": [{"content": {"parts": [{"text": "Hello there!"}]}}]}
        """.data(using: .utf8)!

        let text = GeminiProvider.extractText(fromResponseBody: responseJSON)
        XCTAssertEqual(text, "Hello there!")
    }
}
