import XCTest
@testable import AiPersona

final class LocalEmbedderTests: XCTestCase {

    func test_embed_similarSentences_scoreHigherThanUnrelatedOnes() {
        let a = LocalEmbedder.embed("the user likes concise replies")
        let b = LocalEmbedder.embed("the user prefers short concise answers")
        let c = LocalEmbedder.embed("the weather is sunny today")

        let similarScore = LocalEmbedder.cosineSimilarity(a, b)
        let unrelatedScore = LocalEmbedder.cosineSimilarity(a, c)

        XCTAssertGreaterThan(similarScore, unrelatedScore)
    }

    func test_embed_emptyString_returnsEmptyVector_withoutCrashing() {
        XCTAssertEqual(LocalEmbedder.embed(""), [])
    }

    func test_cosineSimilarity_identicalVectors_isOne() {
        let vector = LocalEmbedder.embed("some text to embed")
        XCTAssertEqual(LocalEmbedder.cosineSimilarity(vector, vector), 1.0, accuracy: 0.0001)
    }

    func test_cosineSimilarity_emptyVectors_returnsZero_withoutCrashing() {
        XCTAssertEqual(LocalEmbedder.cosineSimilarity([], []), 0)
    }
}
