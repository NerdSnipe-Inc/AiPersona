import Foundation
import AIChatCore
import AIChatMLX
import AIChatOpenAI
import AIChatAnthropic

/// Wraps any `ChatProvider` (local or external) as a `MemoryProvider` — the extraction call is
/// just `complete(messages:model:options:)` with `ExtractionPromptFormat.instruction` as the
/// system prompt, identical in shape across OpenAI/Anthropic/Gemini since they all conform to the
/// same `ChatProvider` protocol.
public struct ExternalMemoryProvider: MemoryProvider {
    let chatProvider: any ChatProvider
    let model: String

    public init(chatProvider: any ChatProvider, model: String) {
        self.chatProvider = chatProvider
        self.model = model
    }

    public func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] {
        let options = ChatRequestOptions(systemPrompt: ExtractionPromptFormat.instruction)
        let result = try await chatProvider.complete(
            messages: [ChatMessage(role: .user, content: text)], model: model, options: options
        )
        guard case .text(let output) = result.message.content.first else { return [] }
        return ExtractionPromptFormat.parse(output)
    }
}

/// Builds the active `MemoryProvider` for extraction, per `MemorySettingsStore.extractionProvider`.
/// A missing API key for a selected external provider falls back to local — extraction is a
/// background enhancement, never something that should hard-fail the pipeline for a misconfigured
/// setting. `mlxProvider`/`modelId`/`serialize` are supplied by the host app, since only it knows
/// its shared MLX provider instance, selected model id, and generation-serialization mechanism.
@MainActor
public enum MemoryProviderFactory {
    public static func makeExtractionProvider(
        mlxProvider: MLXProvider,
        modelId: String,
        serialize: @escaping @Sendable (@escaping @Sendable () async throws -> String) async throws -> String = { try await $0() }
    ) -> MemoryProvider {
        let settings = MemorySettingsStore.shared
        let localFallback = LocalMemoryProvider(mlxProvider: mlxProvider, modelId: modelId, serialize: serialize)
        switch settings.extractionProvider {
        case .local:
            return localFallback
        case .gemini:
            guard let key = settings.apiKey(for: .gemini) else { return localFallback }
            return ExternalMemoryProvider(chatProvider: GeminiProvider(apiKey: key), model: "gemini-2.5-flash")
        case .openAI:
            guard let key = settings.apiKey(for: .openAI) else { return localFallback }
            return ExternalMemoryProvider(chatProvider: OpenAIProvider(apiKey: key), model: "gpt-4o-mini")
        case .anthropic:
            guard let key = settings.apiKey(for: .anthropic) else { return localFallback }
            return ExternalMemoryProvider(chatProvider: AnthropicProvider(apiKey: key), model: "claude-3-5-haiku-latest")
        }
    }
}
