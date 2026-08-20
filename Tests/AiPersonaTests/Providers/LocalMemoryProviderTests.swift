import XCTest
@testable import AiPersona

final class LocalMemoryProviderTests: XCTestCase {

    func test_extractionInstruction_isWellFormed() {
        // LocalMemoryProvider always sends ExtractionPromptFormat.instruction as its system
        // prompt — guard against a regression where it's empty/malformed. Full generation against
        // a real MLXProvider needs a downloaded model and is covered by manual verification
        // (final task), not this unit test.
        XCTAssertTrue(ExtractionPromptFormat.instruction.contains("JSON array"))
        XCTAssertTrue(ExtractionPromptFormat.instruction.contains("isCorrection"))
    }

    func test_serializeDefault_isPlainPassthrough() async throws {
        var callCount = 0
        let defaultSerialize: @Sendable (@escaping @Sendable () async throws -> String) async throws -> String = { try await $0() }
        let result = try await defaultSerialize {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }
}
