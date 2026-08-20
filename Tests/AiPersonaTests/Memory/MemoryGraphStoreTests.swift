import XCTest
@testable import AiPersona

@MainActor
final class MemoryGraphStoreTests: XCTestCase {

    func test_upsertEntity_returnsSameNode_whenNameAlreadyExists() {
        let store = MemoryGraphStore(inMemory: true)
        let first = store.upsertEntity(name: "Jane Doe", summary: "A discussed person.", kind: .subject, embedding: [0.1])
        let second = store.upsertEntity(name: "jane doe", summary: "Updated summary.", kind: .subject, embedding: [0.2])

        XCTAssertEqual(first.id, second.id, "matching should be case-insensitive by name")
        XCTAssertEqual(store.allEntities().count, 1)
        XCTAssertEqual(second.summary, "Updated summary.")
    }

    func test_upsertEntity_mergesOntoExistingNode_whenNameIsAFuzzyMatch() {
        let store = MemoryGraphStore(inMemory: true)
        let first = store.upsertEntity(name: "Juan", summary: "A discussed person.", kind: .subject, embedding: [])
        let second = store.upsertEntity(name: "Juan Gómez", summary: "Updated summary.", kind: .subject, embedding: [])

        XCTAssertEqual(first.id, second.id, "fuzzy name match should resolve to the same entity")
        XCTAssertEqual(store.allEntities().count, 1)
    }

    func test_upsertEntity_addsFuzzyMatchedName_asAlias_preservingOriginalName() {
        let store = MemoryGraphStore(inMemory: true)
        let first = store.upsertEntity(name: "Juan", summary: "A discussed person.", kind: .subject, embedding: [])
        store.upsertEntity(name: "Juan Gómez", summary: "Updated summary.", kind: .subject, embedding: [])

        XCTAssertEqual(first.name, "Juan", "canonical name should not be overwritten by a fuzzy-matched alias")
        XCTAssertEqual(first.aliases, ["Juan Gómez"])
    }

    func test_upsertEntity_doesNotMerge_unrelatedSingleWordNames() {
        let store = MemoryGraphStore(inMemory: true)
        let first = store.upsertEntity(name: "Juan", summary: "A discussed person.", kind: .subject, embedding: [])
        let second = store.upsertEntity(name: "Maria", summary: "A different person.", kind: .subject, embedding: [])

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.allEntities().count, 2)
    }

    func test_invalidateFacts_subjectOnly_returnsTrue_whenAFactWasInvalidated() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let embedding = LocalEmbedder.embed("wants the O-1 visa")
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: embedding)

        let didInvalidate = store.invalidateFacts(subjectID: user.id, objectID: nil, relatedTo: embedding)

        XCTAssertTrue(didInvalidate)
        XCTAssertEqual(store.activeFacts().count, 0)
    }

    func test_invalidateFacts_subjectOnly_returnsFalse_whenNothingClearsTheSimilarityBar() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(
            subjectID: user.id, objectID: nil, predicate: "prefers",
            factText: "prefers dark mode", embedding: LocalEmbedder.embed("prefers dark mode")
        )

        let unrelatedCorrectionEmbedding = LocalEmbedder.embed("wants the O-1 visa")
        let didInvalidate = store.invalidateFacts(subjectID: user.id, objectID: nil, relatedTo: unrelatedCorrectionEmbedding)

        XCTAssertFalse(didInvalidate)
        XCTAssertEqual(store.activeFacts().count, 1, "an unrelated correction must not wipe an unrelated fact")
    }

    func test_invalidateFacts_subjectAndObject_returnsFalse_whenNoActiveFactMatches() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])

        let didInvalidate = store.invalidateFacts(subjectID: user.id, objectID: UUID(), relatedTo: [])

        XCTAssertFalse(didInvalidate)
    }

    func test_addFact_thenInvalidate_excludesItFromActiveFacts() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        store.addFact(subjectID: user.id, objectID: nil, predicate: "wants", factText: "wants the O-1 visa", embedding: [0.1])

        XCTAssertEqual(store.activeFacts().count, 1)

        store.invalidateFacts(subjectID: user.id, predicate: "wants")

        XCTAssertEqual(store.activeFacts().count, 0)
        XCTAssertEqual(store.allFacts().count, 1, "invalidated facts remain in history")
        XCTAssertNotNil(store.allFacts()[0].invalidAt)
    }

    func test_visualizationExport_reflectsCurrentEntitiesAndActiveFacts() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let visa = store.upsertEntity(name: "O-1 visa", summary: "A visa category.", kind: .subject, embedding: [])
        store.addFact(subjectID: user.id, objectID: visa.id, predicate: "wants", factText: "wants the O-1 visa", embedding: [])

        let export = store.visualizationExport()

        XCTAssertEqual(export.nodes.count, 2)
        XCTAssertEqual(export.links, [GraphVisualizationLink(source: user.id.uuidString, target: visa.id.uuidString, label: "wants")])
    }

    func test_addEpisode_isRetrievable() {
        let store = MemoryGraphStore(inMemory: true)
        let episode = store.addEpisode(rawText: "user: hi\nassistant: hello", summary: "greeting", occurredAt: Date())

        XCTAssertFalse(episode.rawText.isEmpty)
    }

    func test_entityNode_externalRef_defaultsToNilAndCanBeSet() {
        let entity = EntityNode(name: "Jane Doe", summary: "A contact", kind: .subject, embedding: [])
        XCTAssertNil(entity.externalRef)

        let linked = EntityNode(
            name: "Jane Doe", summary: "A contact", kind: .subject, embedding: [], externalRef: "ghl-contact-abc123"
        )
        XCTAssertEqual(linked.externalRef, "ghl-contact-abc123")
    }

    func test_upsertEntity_withExternalRef_createsEntityFindableByRef() {
        let store = MemoryGraphStore(inMemory: true)
        let entity = store.upsertEntity(
            externalRef: "ghl-contact-abc123", name: "Jane Doe", summary: "A contact",
            kind: .subject, embedding: []
        )
        XCTAssertEqual(entity.externalRef, "ghl-contact-abc123")
        XCTAssertEqual(store.findEntity(externalRef: "ghl-contact-abc123")?.id, entity.id)
    }

    func test_upsertEntity_withExternalRef_matchExistingByRefNotByName() {
        let store = MemoryGraphStore(inMemory: true)
        let first = store.upsertEntity(
            externalRef: "ghl-contact-abc123", name: "Jane Doe", summary: "first summary",
            kind: .subject, embedding: []
        )
        // Same externalRef, different name text (e.g. contact was renamed in GHL) — must update the
        // SAME node by ref, not create a second one or fall through to name-based matching.
        let second = store.upsertEntity(
            externalRef: "ghl-contact-abc123", name: "Jane Smith", summary: "second summary",
            kind: .subject, embedding: []
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.summary, "second summary")
        XCTAssertEqual(store.allEntities().count, 1)
    }

    func test_findEntity_externalRef_returnsNilWhenNotFound() {
        let store = MemoryGraphStore(inMemory: true)
        XCTAssertNil(store.findEntity(externalRef: "ghl-contact-does-not-exist"))
    }

    func test_invalidateFact_byId_invalidatesOnlyThatFact_notSiblingsUnderSamePredicate() {
        let store = MemoryGraphStore(inMemory: true)
        let entity = store.upsertEntity(name: "Jane Doe", summary: "A contact", kind: .subject, embedding: [])
        let first = store.addFact(subjectID: entity.id, objectID: nil, predicate: "task", factText: "task one", embedding: [])
        let second = store.addFact(subjectID: entity.id, objectID: nil, predicate: "task", factText: "task two", embedding: [])

        let didInvalidate = store.invalidateFact(id: first.id)

        XCTAssertTrue(didInvalidate)
        let active = store.activeFacts().filter { $0.subjectID == entity.id }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, second.id, "sibling fact under the same predicate must remain active")
    }

    func test_invalidateFact_byId_returnsFalse_whenIdDoesNotMatchAnyActiveFact() {
        let store = MemoryGraphStore(inMemory: true)
        XCTAssertFalse(store.invalidateFact(id: UUID()))
    }

    func test_invalidateFact_byId_returnsFalse_whenAlreadyInvalidated() {
        let store = MemoryGraphStore(inMemory: true)
        let entity = store.upsertEntity(name: "Jane Doe", summary: "A contact", kind: .subject, embedding: [])
        let fact = store.addFact(subjectID: entity.id, objectID: nil, predicate: "task", factText: "task one", embedding: [])

        XCTAssertTrue(store.invalidateFact(id: fact.id))
        XCTAssertFalse(store.invalidateFact(id: fact.id), "invalidating an already-invalidated fact is a no-op")
    }

    func test_deleteAll_removesEveryEntityEpisodeAndFact() {
        let store = MemoryGraphStore(inMemory: true)
        let user = store.upsertEntity(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let visa = store.upsertEntity(name: "O-1 visa", summary: "A visa category.", kind: .subject, embedding: [])
        store.addFact(subjectID: user.id, objectID: visa.id, predicate: "wants", factText: "wants the O-1 visa", embedding: [])
        store.addEpisode(rawText: "user: hi\nassistant: hello", summary: "greeting", occurredAt: Date())

        store.deleteAll()

        XCTAssertEqual(store.allEntities().count, 0)
        XCTAssertEqual(store.allFacts().count, 0)
        XCTAssertEqual(store.allEpisodes().count, 0)
    }
}
