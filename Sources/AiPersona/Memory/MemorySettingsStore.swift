import Foundation
import Observation

/// Which backend performs a given memory-pipeline role. `local` needs no setup (on-device MLX +
/// `NLEmbedding`); the others are opt-in and require an API key.
public enum MemoryProviderKind: String, CaseIterable, Codable, Sendable {
    case local
    case gemini
    case openAI
    case anthropic
}

/// Persisted memory-pipeline provider selection — extraction and chat generation are
/// independently selectable — plus per-provider API keys via `PersonaKeychain`.
@MainActor
@Observable
public final class MemorySettingsStore {
    public static let shared = MemorySettingsStore()

    private static let extractionProviderKey = "com.aipersona.memory.extractionProvider"
    private static let chatProviderKey = "com.aipersona.memory.chatProvider"
    private static func apiKeyStorageKey(for kind: MemoryProviderKind) -> String {
        "com.aipersona.memory.apiKey.\(kind.rawValue)"
    }

    private let defaults: UserDefaults

    public private(set) var extractionProvider: MemoryProviderKind
    public private(set) var chatProvider: MemoryProviderKind

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let extractionRaw = defaults.string(forKey: Self.extractionProviderKey)
        self.extractionProvider = extractionRaw.flatMap(MemoryProviderKind.init(rawValue:)) ?? .local
        let chatRaw = defaults.string(forKey: Self.chatProviderKey)
        self.chatProvider = chatRaw.flatMap(MemoryProviderKind.init(rawValue:)) ?? .local
    }

    public func selectExtractionProvider(_ kind: MemoryProviderKind) {
        guard kind != extractionProvider else { return }
        extractionProvider = kind
        defaults.set(kind.rawValue, forKey: Self.extractionProviderKey)
    }

    public func selectChatProvider(_ kind: MemoryProviderKind) {
        guard kind != chatProvider else { return }
        chatProvider = kind
        defaults.set(kind.rawValue, forKey: Self.chatProviderKey)
    }

    public func apiKey(for kind: MemoryProviderKind) -> String? {
        PersonaKeychain.load(forKey: Self.apiKeyStorageKey(for: kind))
    }

    public func setAPIKey(_ key: String, for kind: MemoryProviderKind) {
        try? PersonaKeychain.save(key, forKey: Self.apiKeyStorageKey(for: kind))
    }

    public func clearAPIKey(for kind: MemoryProviderKind) {
        PersonaKeychain.delete(forKey: Self.apiKeyStorageKey(for: kind))
    }
}
