import Foundation
import Observation

/// Persisted agent name + personality — the host app injects these into its own chat system
/// prompt (see `PersonaPromptBuilder`). A single shared instance, backed directly by
/// `UserDefaults` (no persistence framework needed for settings-sized state).
@MainActor
@Observable
public final class PersonaStore {
    public static let shared = PersonaStore()

    private static let nameKey = "com.aipersona.persona.name"
    private static let personalityKey = "com.aipersona.persona.personality"
    private static let userNameKey = "com.aipersona.persona.userName"
    public static let defaultName = "Assistant"
    public static let defaultPersonality = "Helpful, concise, and direct."

    private let defaults: UserDefaults

    public private(set) var name: String
    public private(set) var personality: String
    /// The human using the app — distinct from `name`, which is the AI persona's own name.
    /// Empty until the user sets it; a host app should not assume it's populated.
    public private(set) var userName: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.name = defaults.string(forKey: Self.nameKey) ?? Self.defaultName
        self.personality = defaults.string(forKey: Self.personalityKey) ?? Self.defaultPersonality
        self.userName = defaults.string(forKey: Self.userNameKey) ?? ""
    }

    public func update(name: String, personality: String) {
        guard name != self.name || personality != self.personality else { return }
        self.name = name
        self.personality = personality
        defaults.set(name, forKey: Self.nameKey)
        defaults.set(personality, forKey: Self.personalityKey)
    }

    @discardableResult
    public func updateUserName(_ newValue: String) -> Bool {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != userName else { return false }
        userName = trimmed
        defaults.set(trimmed, forKey: Self.userNameKey)
        return true
    }
}
