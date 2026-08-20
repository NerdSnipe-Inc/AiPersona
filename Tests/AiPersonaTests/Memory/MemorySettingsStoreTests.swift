import XCTest
@testable import AiPersona

@MainActor
final class MemorySettingsStoreTests: XCTestCase {

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        for kind in MemoryProviderKind.allCases {
            PersonaKeychain.delete(forKey: "com.aipersona.memory.apiKey.\(kind.rawValue)")
        }
        super.tearDown()
    }

    func test_defaultsToLocalProvider_forBothExtractionAndChat() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = MemorySettingsStore(defaults: defaults)

        XCTAssertEqual(store.extractionProvider, .local)
        XCTAssertEqual(store.chatProvider, .local)
    }

    func test_selectProviders_independently_andPersist() {
        let suiteName = #function
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MemorySettingsStore(defaults: defaults)
        store.selectExtractionProvider(.gemini)
        store.selectChatProvider(.anthropic)

        XCTAssertEqual(store.extractionProvider, .gemini)
        XCTAssertEqual(store.chatProvider, .anthropic)

        let relaunched = MemorySettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.extractionProvider, .gemini)
        XCTAssertEqual(relaunched.chatProvider, .anthropic)
    }

    func test_apiKey_savesAndLoadsFromKeychain_perProvider() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = MemorySettingsStore(defaults: defaults)

        XCTAssertNil(store.apiKey(for: .gemini))

        store.setAPIKey("test-gemini-key", for: .gemini)
        XCTAssertEqual(store.apiKey(for: .gemini), "test-gemini-key")
        XCTAssertNil(store.apiKey(for: .openAI), "keys must not leak across providers")

        store.clearAPIKey(for: .gemini)
        XCTAssertNil(store.apiKey(for: .gemini))
    }
}
