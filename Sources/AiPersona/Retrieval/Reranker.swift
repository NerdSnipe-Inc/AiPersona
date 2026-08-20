import Foundation
import AIChatCore

/// Re-scores `perTurnMemoryBlock`'s already-hybrid-ranked candidates using an LLM's judgment —
/// synapse-cortex's Gemini reranking feature. A quality enhancement, never a correctness
/// requirement: implementations should fall back to returning `candidates` unchanged on any
/// failure rather than throw, matching this package's existing "a background enhancement must
/// never break the primary path" convention (see `IngestionActor.enqueue`'s extraction-failure
/// handling). Off by default everywhere it's used — AiPersona's retrieval is deliberately
/// zero-LLM-overhead/deterministic by design (see `RetrievalService`'s file doc comment); a host
/// app opts in by supplying a `Reranker`, nothing here runs one automatically.
public protocol Reranker: Sendable {
    /// Returns `candidates` reordered by relevance to `query`. May reorder without dropping or
    /// adding entries; on failure, return `candidates` unchanged.
    func rerank(query: String, candidates: [String]) async -> [String]
}

/// Reranks via any `ChatProvider` (Gemini, OpenAI, Anthropic, local MLX, ...) — a general chat
/// completion is enough for this; no fine-tuned reranking model is required, matching what
/// synapse-cortex uses Gemini for.
public struct ChatProviderReranker: Reranker {
    private let provider: any ChatProvider
    private let model: String

    public init(provider: any ChatProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    static func buildPrompt(query: String, candidates: [String]) -> String {
        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Rank the following facts by how relevant they are to answering this query, most relevant \
        first. Query: "\(query)"

        Facts:
        \(numbered)

        Respond with ONLY a JSON array of the fact numbers in ranked order, e.g. [3, 1, 2]. \
        Include every number from 1 to \(candidates.count) exactly once — nothing added, nothing \
        left out.
        """
    }

    /// Same defensive-substring convention as `ExtractionPromptFormat.parse`: takes the text
    /// between the first `[` and last `]` rather than requiring the whole response to be bare
    /// JSON, since models often wrap output in prose or a markdown fence. Returns `nil` — not a
    /// partial/best-effort reordering — unless the result is exactly a permutation of
    /// `1...candidateCount`; a malformed response is precisely the case the caller must fall back
    /// on, not one to guess through (e.g. silently dropping a number would silently drop a fact).
    static func parseOrder(fromResponseText text: String, candidateCount: Int) -> [Int]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
        guard let order = try? JSONDecoder().decode([Int].self, from: data) else { return nil }
        guard candidateCount > 0, Set(order) == Set(1...candidateCount) else { return nil }
        return order
    }

    public func rerank(query: String, candidates: [String]) async -> [String] {
        guard candidates.count > 1 else { return candidates }
        let prompt = Self.buildPrompt(query: query, candidates: candidates)
        guard let result = try? await provider.complete(
            messages: [ChatMessage(role: .user, content: prompt)], model: model, options: ChatRequestOptions()
        ), case .text(let text) = result.message.content.first,
            let order = Self.parseOrder(fromResponseText: text, candidateCount: candidates.count)
        else { return candidates }
        return order.map { candidates[$0 - 1] }
    }
}
