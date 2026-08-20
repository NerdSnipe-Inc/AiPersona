import XCTest
@testable import AiPersona

private struct StubMemoryProvider: MemoryProvider {
    let facts: [ExtractedFact]
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { facts }
}

final class IngestionActorTests: XCTestCase {

    @MainActor
    func test_enqueue_newFact_addsEntitiesAndFactEdge() async {
        let store = MemoryGraphStore(inMemory: true)
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "prefers", factText: "prefers concise replies", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "I prefer short answers", assistantText: "Got it.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 1)
        XCTAssertEqual(store.activeFacts()[0].factText, "prefers concise replies")
        XCTAssertNotNil(store.findEntity(named: "User"))
    }

    @MainActor
    func test_enqueue_correctionFact_invalidatesMatchingExistingFact() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])
        let episode = ChatEpisode(userText: "Actually I don't want that anymore", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 0)
        XCTAssertEqual(store.allFacts().count, 1)
    }

    @MainActor
    func test_enqueue_correctionFact_withDifferentPredicateThanOriginal_stillInvalidatesIt() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))

        // The correction naturally arrives with a DIFFERENT predicate string than the original fact
        // (e.g. "no longer wants" vs. "wants") — this reproduces the review finding.
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "no longer wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])
        let episode = ChatEpisode(userText: "Actually I don't want that anymore", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 0, "correction should invalidate the original fact despite the differing predicate string")
        XCTAssertEqual(store.allFacts().count, 1)
    }

    /// Regression test for the broad-invalidation bug: a single subject-only correction must NOT
    /// wipe out every other unrelated subject-only fact. Seeds two distinct active facts sharing
    /// the same subject entity (as virtually all personal facts do, since `IngestionActor` always
    /// upserts the correction's subject as `kind: .user`), then issues a correction that is
    /// semantically about only ONE of them (and, per the original bug, uses a DIFFERENT predicate
    /// string than the fact it corrects). The old broad implementation invalidated BOTH facts
    /// whenever `objectID` was nil — this test would fail against that code, since it asserts the
    /// unrelated fact survives.
    @MainActor
    func test_enqueue_correctionFact_withMultipleUnrelatedSubjectOnlyFacts_onlyInvalidatesTargetedOne() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: LocalEmbedder.embed("prefers dark mode"))
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "no longer wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])
        let episode = ChatEpisode(userText: "I no longer want the O-1 visa", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        let active = store.activeFacts()
        XCTAssertEqual(active.count, 1, "only the targeted fact should be invalidated, not the unrelated one")
        XCTAssertEqual(active.first?.factText, "prefers dark mode", "the unrelated dark-mode preference must survive the visa correction")
        XCTAssertEqual(store.allFacts().count, 2)
    }

    @MainActor
    func test_enqueue_correctionThatMatchesNothing_isReturned_asAFailedCorrection() async {
        let store = MemoryGraphStore(inMemory: true)
        let correction = ExtractedFact(
            subjectName: "User", objectName: nil, predicate: "no longer wants",
            factText: "no longer wants the O-1 visa", isCorrection: true
        )
        let provider = StubMemoryProvider(facts: [correction])
        let episode = ChatEpisode(userText: "I no longer want that", assistantText: "Noted.", occurredAt: Date())

        let failedCorrections = await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(failedCorrections, [correction], "a correction with nothing to invalidate must be surfaced, not silently dropped")
    }

    @MainActor
    func test_enqueue_correctionThatSucceeds_isNotReturned_asFailed() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: LocalEmbedder.embed("wants the O-1 visa"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "no longer wants", factText: "no longer wants the O-1 visa", isCorrection: true)
        ])
        let episode = ChatEpisode(userText: "Actually I don't want that anymore", assistantText: "Noted.", occurredAt: Date())

        let failedCorrections = await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(failedCorrections, [])
    }

    /// Regression test for a real production bug: the on-device extractor sometimes returns "I" as
    /// a literal subject/object name (unable to resolve the pronoun to anything), which used to
    /// create a junk "I" entity. `IngestionActor` must drop any fact using a bare pronoun as its
    /// subject or object, as a backstop independent of prompt compliance.
    @MainActor
    func test_enqueue_pronounSubject_isDropped() async {
        let store = MemoryGraphStore(inMemory: true)
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "I", objectName: nil, predicate: "likes", factText: "likes coffee", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "I like coffee", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 0)
        XCTAssertNil(store.findEntity(named: "I"))
    }

    @MainActor
    func test_enqueue_pronounObject_isDropped() async {
        let store = MemoryGraphStore(inMemory: true)
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "Alex", objectName: "you", predicate: "trusts", factText: "Alex trusts you", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "Alex trusts you", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 0)
    }

    /// Regression test for a real production bug: once the system prompt started stating the
    /// current date/time every turn (`PersonaPromptBuilder.identityPreamble`), the extractor began
    /// saving "The current date is X" / "The current time is X" as permanent memories — stale and
    /// meaningless the moment the session ends. Must be dropped even if the prompt fix is bypassed.
    @MainActor
    func test_enqueue_currentDateOrTimeFact_isDropped() async {
        let store = MemoryGraphStore(inMemory: true)
        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "the date", objectName: nil, predicate: "is", factText: "The current date is Thursday, August 20, 2026.", isCorrection: false),
            ExtractedFact(subjectName: "the time", objectName: nil, predicate: "is", factText: "The current time is 11:27 AM.", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "What's today's date and time?", assistantText: "It's Thursday, August 20, 2026 at 11:27 AM.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 0)
    }

    /// `addFact` itself has no dedup — `IngestionActor` must not add a second row for a fact whose
    /// text exactly matches one already active for the same subject (e.g. re-asking a question the
    /// user already answered must not double the memory).
    @MainActor
    func test_enqueue_exactDuplicateFact_isNotAddedTwice() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: LocalEmbedder.embed("prefers dark mode"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "prefers", factText: "prefers dark mode", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "I prefer dark mode", assistantText: "Got it.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 1, "an exact-text repeat must not create a second row")
    }

    /// Regression test for a real production complaint: the same preference getting re-saved every
    /// conversation with slightly different wording. The exact-text-only dedup this replaces would
    /// have let this through as a second row; the embedding-similarity check must catch it.
    @MainActor
    func test_enqueue_nearDuplicateFact_isNotAddedTwice() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: LocalEmbedder.embed("prefers dark mode"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "prefers", factText: "really likes dark mode", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "Yeah I really like dark mode", assistantText: "Got it.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 1, "a reworded repeat of an active fact must not create a second row")
    }

    /// The near-duplicate check must not merge two facts that are merely about the same subject
    /// and topic area but are genuinely different information — only near-identical wording should
    /// collapse, per `IngestionActor.duplicateSimilarityThreshold`'s high, deliberately conservative
    /// bar (mirrors `test_enqueue_correctionFact_withMultipleUnrelatedSubjectOnlyFacts_...` above,
    /// same principle applied to plain fact addition instead of correction targeting).
    @MainActor
    func test_enqueue_unrelatedFact_sharingSubject_isStillAdded() async {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: LocalEmbedder.embed("prefers dark mode"))

        let provider = StubMemoryProvider(facts: [
            ExtractedFact(subjectName: "User", objectName: nil, predicate: "wants", factText: "wants the O-1 visa", isCorrection: false)
        ])
        let episode = ChatEpisode(userText: "I want the O-1 visa", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store)

        XCTAssertEqual(store.activeFacts().count, 2, "an unrelated fact about the same subject must not be treated as a duplicate")
    }

    /// `knownUserName` lets the model resolve "I"/"me" to the user's real name instead of
    /// extracting a bare pronoun — verifies the episode text actually carries that context.
    @MainActor
    func test_enqueue_knownUserName_isPrependedToEpisodeText() async {
        actor CapturingProvider: MemoryProvider {
            private(set) var capturedText: String?
            func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] {
                capturedText = text
                return []
            }
        }
        let store = MemoryGraphStore(inMemory: true)
        let provider = CapturingProvider()
        let episode = ChatEpisode(userText: "I like coffee", assistantText: "Noted.", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: provider, store: store, knownUserName: "Daniel")

        let capturedText = await provider.capturedText
        XCTAssertEqual(capturedText?.hasPrefix("Known user name: Daniel\n"), true)
    }

    @MainActor
    func test_enqueue_extractionThrows_doesNotCrash_andLeavesGraphUnchanged() async {
        struct ThrowingProvider: MemoryProvider {
            func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { throw URLError(.badServerResponse) }
        }
        let store = MemoryGraphStore(inMemory: true)
        let episode = ChatEpisode(userText: "hi", assistantText: "hello", occurredAt: Date())

        await IngestionActor.shared.enqueue(episode, provider: ThrowingProvider(), store: store)

        XCTAssertEqual(store.allFacts().count, 0)
    }
}
