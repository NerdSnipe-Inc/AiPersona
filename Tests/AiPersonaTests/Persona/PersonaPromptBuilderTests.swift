import XCTest
@testable import AiPersona

final class PersonaPromptBuilderTests: XCTestCase {

    func test_identityPreamble_includesNameAndPersonality() {
        let preamble = PersonaPromptBuilder.identityPreamble(name: "Sage", personality: "Warm and encouraging.")

        XCTAssertTrue(preamble.contains("Sage"))
        XCTAssertTrue(preamble.contains("Warm and encouraging."))
    }

    func test_identityPreamble_instructsModelItHasPersistentMemory() {
        let preamble = PersonaPromptBuilder.identityPreamble(name: "Sage", personality: "Warm.")

        // Regression guard: a small on-device model with no instruction that this app has a
        // memory system will fall back to its trained "I'm just an AI, I don't retain things"
        // disclaimer the instant a user says "remember X" — even on the very first turn, before
        // any memoryContext exists yet. This must be true unconditionally, not only when
        // memorySection(_:) has content.
        XCTAssertTrue(preamble.lowercased().contains("memory"))
        XCTAssertTrue(preamble.lowercased().contains("remember"))
    }

    func test_memorySection_empty_whenContextIsNil() {
        XCTAssertEqual(PersonaPromptBuilder.memorySection(nil), "")
    }

    func test_memorySection_empty_whenContextIsEmptyString() {
        XCTAssertEqual(PersonaPromptBuilder.memorySection(""), "")
    }

    func test_memorySection_includesMarkerAndContext_whenProvided() {
        let section = PersonaPromptBuilder.memorySection("User prefers concise replies.")

        XCTAssertTrue(section.contains("RELEVANT MEMORY"))
        XCTAssertTrue(section.contains("User prefers concise replies."))
    }

    func test_memorySection_framesFactsAsEstablishedKnowledge() {
        let section = PersonaPromptBuilder.memorySection("User prefers concise replies.")

        // The block must tell the model to TRUST these facts, not just dump them with no framing
        // — otherwise the model has no reason to treat them as things it "remembers".
        XCTAssertTrue(section.lowercased().contains("already know") || section.lowercased().contains("established"))
    }

    func test_knowledgeSection_empty_whenContextIsNil() {
        XCTAssertEqual(PersonaPromptBuilder.knowledgeSection(nil), "")
    }

    func test_knowledgeSection_empty_whenContextIsEmptyString() {
        XCTAssertEqual(PersonaPromptBuilder.knowledgeSection(""), "")
    }

    func test_knowledgeSection_includesMarkerAndContext_whenProvided() {
        let section = PersonaPromptBuilder.knowledgeSection("Snapshots are versioned deployment artifacts.")

        XCTAssertTrue(section.contains("RELEVANT KNOWLEDGE"))
        XCTAssertTrue(section.contains("Snapshots are versioned deployment artifacts."))
    }

    func test_knowledgeSection_isDistinctFromMemorySection() {
        // A retrieved product-knowledge fact is not something learned about the user — must not
        // reuse the "RELEVANT MEMORY" label, or the model could treat an objective rule as a
        // personal fact about the person it's talking to.
        let section = PersonaPromptBuilder.knowledgeSection("Snapshots are versioned deployment artifacts.")

        XCTAssertFalse(section.contains("RELEVANT MEMORY"))
    }
}
