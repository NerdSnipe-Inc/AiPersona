import XCTest
@testable import AiPersona

@MainActor
final class NotionSettingsStoreTests: XCTestCase {

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        PersonaKeychain.delete(forKey: "com.aipersona.notion.integrationToken")
        super.tearDown()
    }

    func test_defaults_toNilToken_andNilParentPageID() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = NotionSettingsStore(defaults: defaults)

        XCTAssertNil(store.integrationToken)
        XCTAssertNil(store.parentPageID)
    }

    func test_setIntegrationToken_savesAndLoadsFromKeychain() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = NotionSettingsStore(defaults: defaults)

        store.setIntegrationToken("secret_test_token")
        XCTAssertEqual(store.integrationToken, "secret_test_token")

        store.clearIntegrationToken()
        XCTAssertNil(store.integrationToken)
    }

    func test_setParentPageID_persistsAcrossRelaunch() {
        let suiteName = #function
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NotionSettingsStore(defaults: defaults)
        store.setParentPageID("abc123")

        let relaunched = NotionSettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.parentPageID, "abc123")
    }
}
