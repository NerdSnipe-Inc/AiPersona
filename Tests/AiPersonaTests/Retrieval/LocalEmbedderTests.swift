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

    func test_embedWithCoverage_allWordsResolve_reportsFullCoverage() {
        let (_, coverage) = LocalEmbedder.embedWithCoverage("the weather is sunny today")
        XCTAssertEqual(coverage, 1.0, accuracy: 0.0001)
    }

    func test_embedWithCoverage_technicalTerms_reportLowCoverage() {
        // Regression for the OOV problem documented in packs/ghl-core-v1/reviews/
        // finish-knowledge-base.md: NLEmbedding.wordEmbedding(for: .english) has no vector for
        // these exact domain terms, verified directly against this app's real knowledge base.
        for term in ["spf", "dkim", "dmarc", "webhook", "idempotency"] {
            let (vector, coverage) = LocalEmbedder.embedWithCoverage(term)
            XCTAssertEqual(coverage, 0, "expected \(term) to be fully out-of-vocabulary")
            XCTAssertEqual(vector, [], "an all-OOV query should embed to an empty vector, not a misleading zero-ish one")
        }
    }

    func test_embedWithCoverage_mixedQuery_reportsPartialCoverage() {
        let (_, coverage) = LocalEmbedder.embedWithCoverage("how should webhook idempotency be handled")
        // "how", "should", "be", "handled" resolve; "webhook" and "idempotency" don't — well under
        // full coverage, but not literally zero either.
        XCTAssertGreaterThan(coverage, 0)
        XCTAssertLessThan(coverage, 1.0)
    }

    func test_embedWithCoverage_emptyString_returnsZeroCoverage_withoutCrashing() {
        let (vector, coverage) = LocalEmbedder.embedWithCoverage("")
        XCTAssertEqual(vector, [])
        XCTAssertEqual(coverage, 0)
    }
}
