import XCTest
@testable import AiPersona

@MainActor
final class PersonaStoreTests: XCTestCase {

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func test_defaultsToBuiltInIdentity_whenNothingSetYet() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = PersonaStore(defaults: defaults)

        XCTAssertEqual(store.name, "Assistant")
        XCTAssertEqual(store.personality, "Helpful, concise, and direct.")
    }

    func test_update_persistsAcrossStoreReinstantiation() {
        let suiteName = #function
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PersonaStore(defaults: defaults)
        store.update(name: "Sage", personality: "Warm and encouraging, uses plain language.")

        XCTAssertEqual(store.name, "Sage")

        let relaunchedStore = PersonaStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.name, "Sage")
        XCTAssertEqual(relaunchedStore.personality, "Warm and encouraging, uses plain language.")
    }

    func test_update_sameValues_isNoOp() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = PersonaStore(defaults: defaults)
        let initialName = store.name
        store.update(name: initialName, personality: store.personality)

        XCTAssertEqual(store.name, initialName)
    }
}
