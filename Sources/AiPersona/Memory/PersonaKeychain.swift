import Foundation
import Security

enum PersonaKeychainError: Error, Sendable {
    case saveFailed(OSStatus)
}

/// Minimal, self-contained Keychain wrapper — deliberately not shared with any host app's own
/// Keychain helper, so this package has zero dependency on host-app-specific code and stays
/// independently reusable/open-sourceable.
enum PersonaKeychain {
    @discardableResult
    static func save(_ value: String, forKey key: String) throws -> OSStatus {
        let data = Data(value.utf8)
        // The delete query must NOT include kSecAttrAccessible: it's a matchable item
        // attribute, so including it here would only match items already stored with
        // this exact accessibility, leaving any pre-existing item (e.g. saved before
        // this attribute was added) undeleted — and the following SecItemAdd would then
        // fail with errSecDuplicateItem instead of overwriting it.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw PersonaKeychainError.saveFailed(status) }
        return status
    }

    static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
