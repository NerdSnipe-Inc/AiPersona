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
            guard case .text(let output) = result.message.content.first else {
                AiPersonaLog.logger("Extraction").notice("Model returned a non-text message; no facts extracted")
                return ""
            }
            return output
        }
        let logger = AiPersonaLog.logger("Extraction")
        let parsed = ExtractionPromptFormat.parseDetailed(output)
        if parsed.looksUnparseable, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The model answered but not with JSON (refusal, prose, truncation before any object).
            // Facts are lost for this episode — say so, with the raw text for diagnosis.
            logger.error("Extraction output unparseable (\(output.count) chars): \(output.prefix(500), privacy: .private)")
        } else if output.isEmpty {
            logger.notice("Extraction returned empty output")
        } else if parsed.skippedObjects > 0 {
            logger.notice("Extraction dropped \(parsed.skippedObjects) malformed fact object(s), kept \(parsed.facts.count)")
        } else {
            logger.debug("Extraction parsed \(parsed.facts.count) fact(s)")
        }
        return parsed.facts
    }
}
