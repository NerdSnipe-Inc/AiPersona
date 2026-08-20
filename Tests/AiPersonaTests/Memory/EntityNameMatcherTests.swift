import XCTest
@testable import AiPersona

final class EntityNameMatcherTests: XCTestCase {

    func test_matches_isTrue_whenOneNameIsASubsetOfTheOthersTokens() {
        XCTAssertTrue(EntityNameMatcher.matches("Juan", "Juan Gómez"))
    }

    func test_matches_isTrue_whenNamesDifferOnlyByDiacritics() {
        XCTAssertTrue(EntityNameMatcher.matches("Juan Gomez", "Juan Gómez"))
    }

    func test_matches_isTrue_whenOneNameIsInitialsOfTheOther() {
        XCTAssertTrue(EntityNameMatcher.matches("JG", "Juan Gómez"))
    }

    func test_matches_isFalse_forUnrelatedSingleWordNames() {
        XCTAssertFalse(EntityNameMatcher.matches("Juan", "Maria"))
    }

    func test_matches_isFalse_forNamesThatShareNoTokens() {
        XCTAssertFalse(EntityNameMatcher.matches("Juan Perez", "Maria Gomez"))
    }

    func test_matches_isFalse_whenEitherNameIsEmpty() {
        XCTAssertFalse(EntityNameMatcher.matches("", "Juan Gómez"))
        XCTAssertFalse(EntityNameMatcher.matches("Juan", ""))
    }
}
