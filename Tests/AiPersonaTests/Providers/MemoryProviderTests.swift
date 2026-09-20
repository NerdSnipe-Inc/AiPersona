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

    // MARK: - Hostile / messy model output fixtures (no model needed)

    private let good = #"{"subjectName": "Sam", "objectName": "Acme", "predicate": "works at", "factText": "Sam works at Acme.", "isCorrection": false}"#
    private let good2 = #"{"subjectName": "Sam", "objectName": null, "predicate": "is allergic to", "factText": "Sam is allergic to penicillin.", "isCorrection": false}"#

    func test_parse_markdownFence() {
        let facts = ExtractionPromptFormat.parse("```json\n[\(good), \(good2)]\n```")
        XCTAssertEqual(facts.map(\.factText), ["Sam works at Acme.", "Sam is allergic to penicillin."])
    }

    func test_parse_thinkingPrefixWithBrackets() {
        let out = "<think>The user said [name] is Sam; I should output [] or [{...}]. {maybe}</think>\n[\(good)]"
        XCTAssertEqual(ExtractionPromptFormat.parse(out).count, 1)
    }

    func test_parse_unclosedThinkingDropsPreambleOnly() {
        // Nothing after an unclosed <think> can be an answer.
        XCTAssertEqual(ExtractionPromptFormat.parse("<think>hmm [\(good)]").count, 0)
    }

    func test_parse_channelThoughtPrefix() {
        let out = "<|channel>thought\nlet me see [1]<channel|>[\(good)]"
        XCTAssertEqual(ExtractionPromptFormat.parse(out).count, 1)
    }

    func test_parse_truncatedArray_keepsCompleteObjects() {
        let out = "[\(good), \(good2), {\"subjectName\": \"Sam\", \"objectN"
        XCTAssertEqual(ExtractionPromptFormat.parse(out).count, 2)
    }

    func test_parse_oneMalformedElement_doesNotLoseTheOthers() {
        let bad = #"{"subjectName": "Sam", "predicate": "x"}"# // no factText
        let r = ExtractionPromptFormat.parseDetailed("[\(good), \(bad), \(good2)]")
        XCTAssertEqual(r.facts.count, 2)
        XCTAssertEqual(r.skippedObjects, 1)
    }

    func test_parse_bareObjectAndWrapperObject() {
        XCTAssertEqual(ExtractionPromptFormat.parse(good).count, 1)
        XCTAssertEqual(ExtractionPromptFormat.parse(#"{"facts": [\#(good), \#(good2)]}"#).count, 2)
    }

    func test_parse_missingIsCorrection_stringNull_andBracesInsideStrings() {
        let odd = #"{"subjectName": "Sam", "objectName": "null", "predicate": "said", "factText": "Sam wrote {x} and [y] in a note", "isCorrection": "true"}"#
        let facts = ExtractionPromptFormat.parse("[\(odd)]")
        XCTAssertEqual(facts.count, 1)
        XCTAssertNil(facts[0].objectName)
        XCTAssertTrue(facts[0].isCorrection)
        XCTAssertEqual(facts[0].factText, "Sam wrote {x} and [y] in a note")

        let noFlag = #"{"subjectName": "Sam", "predicate": "likes", "factText": "Sam likes tea"}"#
        XCTAssertFalse(ExtractionPromptFormat.parse("[\(noFlag)]")[0].isCorrection)
    }

    func test_parse_proseAroundAndUnicode() {
        let out = "Here you go!\n[\(good)]\nHope that helps — café ☕️"
        XCTAssertEqual(ExtractionPromptFormat.parse(out).count, 1)
    }

    func test_parseDetailed_distinguishesEmptyFromGarbage() {
        XCTAssertFalse(ExtractionPromptFormat.parseDetailed("[]").looksUnparseable)
        XCTAssertFalse(ExtractionPromptFormat.parseDetailed("```json\n[]\n```").looksUnparseable)
        XCTAssertTrue(ExtractionPromptFormat.parseDetailed("I'm sorry, I can't help with that.").looksUnparseable)
    }

    func test_parse_hugeGarbage_isFast() {
        let garbage = String(repeating: "{ [ \"", count: 200_000)
        let start = Date()
        _ = ExtractionPromptFormat.parse(garbage)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
