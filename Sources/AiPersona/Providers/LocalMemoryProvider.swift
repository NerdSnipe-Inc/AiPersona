import Foundation
import AIChatMLX
import AIChatCore

/// Extracts facts using a host app's shared on-device MLX model — no setup required, the default
/// `MemoryProviderKind.local`. `serialize` lets a host app route generation through its own
/// serialization mechanism (this package has no opinion on one); defaults to calling `work`
/// directly for standalone use.
public struct LocalMemoryProvider: MemoryProvider {
    private let mlxProvider: MLXProvider
    private let modelId: String
    private let serialize: @Sendable (@escaping @Sendable () async throws -> String) async throws -> String

    public init(
        mlxProvider: MLXProvider,
        modelId: String,
        serialize: @escaping @Sendable (@escaping @Sendable () async throws -> String) async throws -> String = { try await $0() }
    ) {
        self.mlxProvider = mlxProvider
        self.modelId = modelId
        self.serialize = serialize
    }

    public func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] {
        let provider = mlxProvider
        let modelId = self.modelId
        let output = try await serialize {
            try await provider.loadModel()
            let options = ChatRequestOptions(systemPrompt: ExtractionPromptFormat.instruction)
            let result = try await provider.complete(
                messages: [ChatMessage(role: .user, content: text)], model: modelId, options: options
            )
            guard case .text(let output) = result.message.content.first else { return "" }
            return output
        }
        return ExtractionPromptFormat.parse(output)
    }
}
