import Foundation
import Observation

/// Persisted Notion export/import configuration: the integration token (Keychain, same pattern
/// as `MemorySettingsStore`'s per-provider LLM API keys) and the parent page ID new export
/// databases are created under (`UserDefaults`, not a secret). Single-user simplification: one
/// token for the whole host app instance — synapse-cortex's per-request multi-tenant auth
/// doesn't apply here.
@MainActor
@Observable
public final class NotionSettingsStore {
    public static let shared = NotionSettingsStore()

    private static let integrationTokenKey = "com.aipersona.notion.integrationToken"
    private static let parentPageIDKey = "com.aipersona.notion.parentPageID"

    private let defaults: UserDefaults

    public private(set) var parentPageID: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.parentPageID = defaults.string(forKey: Self.parentPageIDKey)
    }

    public var integrationToken: String? {
        PersonaKeychain.load(forKey: Self.integrationTokenKey)
    }

    public func setIntegrationToken(_ token: String) {
        try? PersonaKeychain.save(token, forKey: Self.integrationTokenKey)
    }

    public func clearIntegrationToken() {
        PersonaKeychain.delete(forKey: Self.integrationTokenKey)
    }

    public func setParentPageID(_ pageID: String) {
        parentPageID = pageID
        defaults.set(pageID, forKey: Self.parentPageIDKey)
    }
}
