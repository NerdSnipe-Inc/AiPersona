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

    func test_sessionCompilation_favorsWellConnectedEntity_overMoreRecentLoneMention() {
        let store = MemoryGraphStore(inMemory: true)
        let alice = store.upsertEntity(name: "Alice", summary: "", kind: .subject, embedding: [])
        let bob = store.upsertEntity(name: "Bob", summary: "", kind: .subject, embedding: [])
        let carol = store.upsertEntity(name: "Carol", summary: "", kind: .subject, embedding: [])
        let dave = store.upsertEntity(name: "Dave", summary: "", kind: .subject, embedding: [])

        // Alice is well-connected: two facts linking her to other entities.
        store.addFact(subjectID: alice.id, objectID: bob.id, predicate: "knows", factText: "Alice knows Bob", embedding: [])
        store.addFact(subjectID: alice.id, objectID: carol.id, predicate: "knows", factText: "Alice knows Carol", embedding: [])

        // Dave is a lone, more recently mentioned entity with a single fact.
        store.addFact(subjectID: dave.id, objectID: nil, predicate: "mentioned", factText: "Dave was mentioned once", embedding: [])

        let service = RetrievalService(store: store, factLimit: 2)
        let compilation = service.sessionCompilation()

        XCTAssertTrue(compilation.contains("Alice knows Bob"))
        XCTAssertTrue(compilation.contains("Alice knows Carol"))
        XCTAssertFalse(compilation.contains("Dave was mentioned once"), "a lone, low-degree entity should lose budget to a well-connected one despite being more recent")
    }

    func test_isCompilationExhaustive_true_whenAllFactsFitUnderBudget() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes tea", embedding: [])

        let service = RetrievalService(store: store, factLimit: 20)

        XCTAssertTrue(service.isCompilationExhaustive(), "one fact well under a factLimit of 20 leaves nothing truncated")
    }

    func test_isCompilationExhaustive_false_whenFactsExceedBudget() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        for i in 0..<10 {
            store.addFact(subjectID: user.id, objectID: nil, predicate: "has", factText: "fact \(i)", embedding: [])
        }

        let service = RetrievalService(store: store, factLimit: 5)

        XCTAssertFalse(service.isCompilationExhaustive(), "10 facts over a factLimit of 5 means the compilation truncated some")
    }

    func test_isCompilationExhaustive_false_afterFactAddedSinceCaching() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes tea", embedding: [])

        let service = RetrievalService(store: store, factLimit: 20)
        XCTAssertTrue(service.isCompilationExhaustive(), "caches the compilation as exhaustive with just one fact")

        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes coffee too", embedding: [])

        XCTAssertFalse(
            service.isCompilationExhaustive(),
            "a fact added after caching is missing from the stale cached compilation text even though the total is still under factLimit — gating must fail closed, not trust the stale count"
        )
    }

    func test_isCompilationExhaustive_resets_onNewSession() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes tea", embedding: [])

        let service = RetrievalService(store: store, factLimit: 20)
        _ = service.isCompilationExhaustive()
        store.addFact(subjectID: user.id, objectID: nil, predicate: "likes", factText: "likes coffee too", embedding: [])
        XCTAssertFalse(service.isCompilationExhaustive())

        service.startNewSession()

        XCTAssertTrue(service.isCompilationExhaustive(), "a fresh session recompiles against the current graph, which is exhaustive again")
    }

    func test_perTurnMemoryBlock_skipsSearch_whenCompilationIsExhaustive() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: LocalEmbedder.embed("User"))
        let factText = "prefers dark mode"
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: factText, embedding: LocalEmbedder.embed(factText))

        let service = RetrievalService(store: store, factLimit: 20)
        let compilation = service.sessionCompilation()
        XCTAssertTrue(compilation.contains(factText))

        // Deliberately query for something that WOULD hybrid-match this fact if search ran, and
        // pass an exclusion text that does NOT contain it — proving any non-nil result here can
        // only come from gating failing to skip the search, not from an unrelated miss.
        let block = service.perTurnMemoryBlock(forQuery: "dark mode preference", excluding: "")

        XCTAssertNil(block, "an exhaustive compilation must gate the search off even when the passed-in exclusion text doesn't itself cover the fact")
    }

    private struct ReversingReranker: Reranker {
        func rerank(query: String, candidates: [String]) async -> [String] { candidates.reversed() }
    }

    private struct MisbehavingReranker: Reranker {
        func rerank(query: String, candidates: [String]) async -> [String] { ["something that was never a candidate"] }
    }

    func test_perTurnMemoryBlockWithReranker_appliesRerankedOrder() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        for i in 0..<10 {
            let text = "fact number \(i) about visas and travel"
            store.addFact(subjectID: user.id, objectID: nil, predicate: "has", factText: text, embedding: LocalEmbedder.embed(text))
        }
        let service = RetrievalService(store: store, factLimit: 3)
        let compilation = service.sessionCompilation()

        let unreranked = service.perTurnMemoryBlock(forQuery: "visas and travel", excluding: compilation, limit: 5)
        let reranked = await service.perTurnMemoryBlock(forQuery: "visas and travel", excluding: compilation, limit: 5, reranker: ReversingReranker())

        XCTAssertNotNil(unreranked)
        XCTAssertNotNil(reranked)
        XCTAssertEqual(reranked, unreranked?.components(separatedBy: "\n").reversed().joined(separator: "\n"), "the reranker's reordering must be reflected in the returned block")
    }

    func test_perTurnMemoryBlockWithReranker_fallsBackToHybridOrder_whenRerankerMisbehaves() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: [])
        for i in 0..<10 {
            let text = "fact number \(i) about visas and travel"
            store.addFact(subjectID: user.id, objectID: nil, predicate: "has", factText: text, embedding: LocalEmbedder.embed(text))
        }
        let service = RetrievalService(store: store, factLimit: 3)
        let compilation = service.sessionCompilation()

        let unreranked = service.perTurnMemoryBlock(forQuery: "visas and travel", excluding: compilation, limit: 5)
        let reranked = await service.perTurnMemoryBlock(forQuery: "visas and travel", excluding: compilation, limit: 5, reranker: MisbehavingReranker())

        XCTAssertEqual(reranked, unreranked, "a reranker returning something that isn't a faithful reorder of the candidates must not corrupt the block")
    }

    func test_perTurnMemoryBlockWithReranker_respectsGating() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "", kind: .user, embedding: LocalEmbedder.embed("User"))
        let factText = "prefers dark mode"
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: factText, embedding: LocalEmbedder.embed(factText))

        let service = RetrievalService(store: store, factLimit: 20)
        _ = service.sessionCompilation()

        let block = await service.perTurnMemoryBlock(forQuery: "dark mode preference", excluding: "", reranker: ReversingReranker())

        XCTAssertNil(block, "the reranked overload must respect isCompilationExhaustive() gating exactly like the sync overload")
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
