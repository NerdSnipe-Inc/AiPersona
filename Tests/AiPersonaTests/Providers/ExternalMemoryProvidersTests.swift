import XCTest
import AIChatCore
@testable import AiPersona

private struct StubChatProvider: ChatProvider {
    let id = "stub"
    let name = "Stub"
    var responseText: String

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        ChatCompletionResult(id: nil, model: model, message: ChatMessage(role: .assistant, content: responseText), usage: nil, finishReason: .stop)
    }
}

final class ExternalMemoryProvidersTests: XCTestCase {

    func test_extractFacts_parsesUnderlyingChatProviderOutput() async throws {
        let stub = StubChatProvider(responseText: """
        [{"subjectName": "User", "objectName": null, "predicate": "prefers", "factText": "prefers dark mode", "isCorrection": false}]
        """)
        let provider = ExternalMemoryProvider(chatProvider: stub, model: "stub-model")

        let facts = try await provider.extractFacts(fromEpisode: "user: I prefer dark mode")

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].factText, "prefers dark mode")
    }

    func test_extractFacts_malformedOutput_returnsEmpty() async throws {
        let stub = StubChatProvider(responseText: "I don't understand.")
        let provider = ExternalMemoryProvider(chatProvider: stub, model: "stub-model")

        let facts = try await provider.extractFacts(fromEpisode: "irrelevant")

        XCTAssertTrue(facts.isEmpty)
    }
}
