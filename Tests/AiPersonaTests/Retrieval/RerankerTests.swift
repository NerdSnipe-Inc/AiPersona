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

private struct ThrowingChatProvider: ChatProvider {
    let id = "throwing"
    let name = "Throwing"

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        throw URLError(.notConnectedToInternet)
    }
}

final class ChatProviderRerankerTests: XCTestCase {

    // MARK: - parseOrder

    func test_parseOrder_parsesCleanJSONArray() {
        let order = ChatProviderReranker.parseOrder(fromResponseText: "[3, 1, 2]", candidateCount: 3)
        XCTAssertEqual(order, [3, 1, 2])
    }

    func test_parseOrder_stripsSurroundingProseOrMarkdownFence() {
        let order = ChatProviderReranker.parseOrder(fromResponseText: "Here you go:\n```json\n[2, 1]\n```", candidateCount: 2)
        XCTAssertEqual(order, [2, 1])
    }

    func test_parseOrder_returnsNil_whenNotAPermutation() {
        XCTAssertNil(ChatProviderReranker.parseOrder(fromResponseText: "[1, 1, 2]", candidateCount: 3), "a repeated index is not a valid permutation")
        XCTAssertNil(ChatProviderReranker.parseOrder(fromResponseText: "[1, 2]", candidateCount: 3), "too few indices must not be treated as a valid reorder")
        XCTAssertNil(ChatProviderReranker.parseOrder(fromResponseText: "[1, 2, 3, 4]", candidateCount: 3), "too many indices must not be treated as a valid reorder")
    }

    func test_parseOrder_returnsNil_whenNoJSONArrayPresent() {
        XCTAssertNil(ChatProviderReranker.parseOrder(fromResponseText: "I'm not sure how to rank these.", candidateCount: 3))
    }

    // MARK: - rerank

    func test_rerank_reordersCandidates_perModelResponse() async {
        let stub = StubChatProvider(responseText: "[2, 1]")
        let reranker = ChatProviderReranker(provider: stub, model: "stub-model")

        let reranked = await reranker.rerank(query: "anything", candidates: ["first", "second"])

        XCTAssertEqual(reranked, ["second", "first"])
    }

    func test_rerank_fallsBackToOriginalOrder_onMalformedResponse() async {
        let stub = StubChatProvider(responseText: "not json at all")
        let reranker = ChatProviderReranker(provider: stub, model: "stub-model")

        let reranked = await reranker.rerank(query: "anything", candidates: ["first", "second"])

        XCTAssertEqual(reranked, ["first", "second"], "a malformed reranker response must degrade to the original order, never drop or duplicate a candidate")
    }

    func test_rerank_fallsBackToOriginalOrder_onProviderFailure() async {
        let reranker = ChatProviderReranker(provider: ThrowingChatProvider(), model: "stub-model")

        let reranked = await reranker.rerank(query: "anything", candidates: ["first", "second"])

        XCTAssertEqual(reranked, ["first", "second"])
    }

    func test_rerank_skipsCall_whenFewerThanTwoCandidates() async {
        // ThrowingChatProvider would fail this test if `rerank` actually called it for a
        // single-candidate (nothing to reorder) or empty list — proves the short-circuit runs.
        let reranker = ChatProviderReranker(provider: ThrowingChatProvider(), model: "stub-model")

        let single = await reranker.rerank(query: "anything", candidates: ["only"])
        let empty = await reranker.rerank(query: "anything", candidates: [])

        XCTAssertEqual(single, ["only"])
        XCTAssertEqual(empty, [])
    }
}
