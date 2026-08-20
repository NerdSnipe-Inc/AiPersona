import XCTest
@testable import AiPersona

@MainActor
final class RetrievalServiceTests: XCTestCase {

    func test_sessionCompilation_includesActiveFacts_excludesInvalidated() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers concise replies", embedding: LocalEmbedder.embed("prefers concise replies"))
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))
        store.invalidateFacts(subjectID: user.id, predicate: "wants")

        let service = RetrievalService(store: store)
        let compilation = service.sessionCompilation()

        XCTAssertTrue(compilation.contains("prefers concise replies"))
        XCTAssertFalse(compilation.contains("wants the O-1 visa"))
    }

    func test_sessionCompilation_isCached_untilStartNewSession() {
        let store = MemoryGraphStore(inMemory: true)
        let service = RetrievalService(store: store)
        _ = service.sessionCompilation()

        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes dark mode", embedding: LocalEmbedder.embed("likes dark mode"))

        XCTAssertFalse(service.sessionCompilation().contains("likes dark mode"))

        service.startNewSession()
        XCTAssertTrue(service.sessionCompilation().contains("likes dark mode"))
    }

    func test_perTurnMemoryBlock_returnsNil_whenNoFactsMatch() {
        let store = MemoryGraphStore(inMemory: true)
        let service = RetrievalService(store: store)

        XCTAssertNil(service.perTurnMemoryBlock(forQuery: "anything", excluding: ""))
    }

    func test_sessionCompilation_isBudgeted_toMostRecentFacts() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])

        var oldestText: String?
        var newestText: String?
        for i in 0..<25 {
            let text = "fact number \(i) about visas and travel"
            if i == 0 { oldestText = text }
            if i == 24 { newestText = text }
            store.addFact(
                subjectID: user.id, objectID: nil, predicate: "has",
                factText: text, embedding: LocalEmbedder.embed(text)
            )
        }

        let service = RetrievalService(store: store, factLimit: 5)
        let compilation = service.sessionCompilation()

        XCTAssertEqual(compilation.components(separatedBy: "\n").count, 5, "compilation should be capped to factLimit")
        XCTAssertTrue(compilation.contains(newestText!), "most recent facts should be in the budgeted compilation")
        XCTAssertFalse(compilation.contains(oldestText!), "facts beyond the budget should be excluded from the compilation")
    }

    func test_perTurnMemoryBlock_canReturnFact_excludedFromBudgetedCompilation() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])

        for i in 0..<25 {
            let text = "fact number \(i) about visas and travel"
            store.addFact(
                subjectID: user.id, objectID: nil, predicate: "has",
                factText: text, embedding: LocalEmbedder.embed(text)
            )
        }

        let service = RetrievalService(store: store, factLimit: 5)
        let compilation = service.sessionCompilation()

        let block = service.perTurnMemoryBlock(forQuery: "visas and travel", excluding: compilation, limit: 20)

        XCTAssertNotNil(block, "hybrid search should be able to surface a fact excluded from the budgeted compilation")
    }

    func test_predicateScopedBlock_onlyMatchesGivenPredicate() {
        let store = MemoryGraphStore(inMemory: true)
        let subject = store.upsertEntity(name: "Knowledge Base", summary: "", kind: .subject, embedding: [])
        let contactText = "deal: Rooftop Install — stage Proposal Sent, value 4200"
        let ruleText = "Snapshots are versioned deployment artifacts."
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "deal", factText: contactText, embedding: LocalEmbedder.embed(contactText))
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "product_rule", factText: ruleText, embedding: LocalEmbedder.embed(ruleText))

        let service = RetrievalService(store: store)
        let block = service.predicateScopedBlock(forQuery: "snapshot deployment", predicate: "product_rule")

        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains(ruleText))
        XCTAssertFalse(block!.contains(contactText), "must not surface facts outside the requested predicate")
    }

    func test_predicateScopedBlock_returnsNil_whenPredicateHasNoFacts() {
        let store = MemoryGraphStore(inMemory: true)
        let subject = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "likes", factText: "likes dark mode", embedding: LocalEmbedder.embed("likes dark mode"))

        let service = RetrievalService(store: store)

        XCTAssertNil(service.predicateScopedBlock(forQuery: "anything", predicate: "product_rule"))
    }

    func test_predicateScopedBlock_returnsNil_whenOnlyCandidateSharesNoLiteralTermsWithQuery() {
        // Regression test for packs/ghl-core-v1/reviews/live-swift-retrieval-results-2026-08-20/
        // README.md: RRF fusion always returns the "best available" candidate from a non-empty
        // pool even when nothing in it is actually relevant, because it only encodes relative
        // rank. Live evaluation caught a real case where this surfaced an unrelated
        // "document delivery" fact for an SPF/DKIM/DMARC question, and the model treated the
        // injected block as authoritative ground truth and deflected instead of answering from
        // what it actually knew. predicateScopedBlock must drop candidates with zero lexical
        // overlap rather than surface them as if they were a real match.
        let store = MemoryGraphStore(inMemory: true)
        let subject = store.upsertEntity(name: "Knowledge Base", summary: "", kind: .subject, embedding: [])
        let unrelatedText = "A sent document is not a completed document: delivery and viewing are distinct states."
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "product_rule", factText: unrelatedText, embedding: LocalEmbedder.embed(unrelatedText))

        let service = RetrievalService(store: store)
        let block = service.predicateScopedBlock(
            forQuery: "How should SPF, DKIM, and DMARC authentication be verified?", predicate: "product_rule"
        )

        XCTAssertNil(block, "a candidate with zero literal term overlap with the query must not be surfaced as ground truth")
    }

    func test_predicateScopedBlock_doesNotCompeteWithSessionCompilationBudget() {
        // The whole point of a separate predicate-scoped call: a large pool of contact facts
        // filling sessionCompilation's factLimit must not crowd out product-knowledge retrieval,
        // which is queried independently against its own predicate slice.
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        for i in 0..<25 {
            let text = "fact number \(i) about visas and travel"
            store.addFact(subjectID: user.id, objectID: nil, predicate: "has", factText: text, embedding: LocalEmbedder.embed(text))
        }
        let ruleText = "Snapshots are versioned deployment artifacts."
        store.addFact(subjectID: user.id, objectID: nil, predicate: "product_rule", factText: ruleText, embedding: LocalEmbedder.embed(ruleText))

        let service = RetrievalService(store: store, factLimit: 5)
        _ = service.sessionCompilation()

        let block = service.predicateScopedBlock(forQuery: "snapshot deployment", predicate: "product_rule")

        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains(ruleText))
    }
}
