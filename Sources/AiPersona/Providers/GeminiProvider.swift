import Foundation
import AIChatCore

/// A `ChatProvider` conformance for Google's Gemini REST API — the one external provider
/// `AIChatKit` doesn't already ship (it has `OpenAIProvider`/`AnthropicProvider`). Implements
/// `complete` directly against Gemini's non-streaming `generateContent` endpoint; `stream` wraps
/// `complete` and emits its full result as a single `.text` event — real token-by-token SSE
/// streaming isn't needed for memory extraction or this package's chat-generation use.
public struct GeminiProvider: ChatProvider {
    public let id = "gemini"
    public let name = "Gemini"

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "gemini-2.5-flash", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// When `cachedContentName` is set (from `GeminiContextCacheService`), references that cache
    /// instead of inlining `options.systemPrompt` — the prompt is already baked into the cache,
    /// so sending it again would defeat the point of caching.
    func buildRequest(messages: [ChatMessage], options: ChatRequestOptions, cachedContentName: String? = nil) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let contents = messages.compactMap { message -> [String: Any]? in
            guard case .text(let text) = message.content.first else { return nil }
            let role = message.role == .assistant ? "model" : "user"
            return ["role": role, "parts": [["text": text]]]
        }

        var body: [String: Any] = ["contents": contents]
        if let cachedContentName {
            body["cachedContent"] = cachedContentName
        } else if let systemPrompt = options.systemPrompt {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractText(fromResponseBody data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else { return "" }
        return text
    }

    public func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        try await complete(messages: messages, model: model, options: options, cachedContentName: nil)
    }

    /// Overload accepting a `GeminiContextCacheService`-produced cache name — a caller with a
    /// compilation cached on Gemini's side uses this instead of the `ChatProvider`-required
    /// 3-parameter `complete` so the compilation isn't resent on every turn.
    public func complete(
        messages: [ChatMessage], model: String, options: ChatRequestOptions, cachedContentName: String?
    ) async throws -> ChatCompletionResult {
        let request = try buildRequest(messages: messages, options: options, cachedContentName: cachedContentName)
        let (data, _) = try await session.data(for: request)
        let text = Self.extractText(fromResponseBody: data)
        return ChatCompletionResult(
            id: nil, model: model, message: ChatMessage(role: .assistant, content: text),
            usage: nil, finishReason: .stop
        )
    }

    public func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await complete(messages: messages, model: model, options: options)
                    guard case .text(let text) = result.message.content.first else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(.text(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
