import XCTest
@testable import AiPersona

final class MemoryProviderTests: XCTestCase {

    func test_parse_validJSON_decodesFacts() {
        let output = """
        Sure, here are the facts:
        [
          {"subjectName": "User", "objectName": null, "predicate": "prefers", "factText": "prefers concise replies", "isCorrection": false},
          {"subjectName": "User", "objectName": "O-1 visa", "predicate": "no longer wants", "factText": "no longer wants the O-1 visa", "isCorrection": true}
        ]
        """
        let facts = ExtractionPromptFormat.parse(output)

        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[0].subjectName, "User")
        XCTAssertNil(facts[0].objectName)
        XCTAssertFalse(facts[0].isCorrection)
        XCTAssertTrue(facts[1].isCorrection)
    }

    func test_parse_malformedJSON_returnsEmptyArray_withoutCrashing() {
        XCTAssertEqual(ExtractionPromptFormat.parse("not json at all").count, 0)
    }

    func test_parse_emptyArray_returnsEmpty() {
        XCTAssertEqual(ExtractionPromptFormat.parse("[]").count, 0)
    }
}
