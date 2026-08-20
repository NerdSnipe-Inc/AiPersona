import XCTest
import SwiftData
@testable import AiPersona

final class MemoryModelsTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([EntityNode.self, EpisodicNode.self, FactEdge.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func test_entityNode_roundTrips_kindAndEmbedding() throws {
        let context = try makeInMemoryContext()
        let entity = EntityNode(name: "Jane Doe", summary: "A discussed person.", kind: .subject, embedding: [0.1, 0.2, 0.3])
        context.insert(entity)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<EntityNode>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].kind, .subject)
        XCTAssertEqual(fetched[0].embedding, [0.1, 0.2, 0.3])
    }

    func test_entityNode_aliases_defaultsToEmpty_andRoundTrips() throws {
        let context = try makeInMemoryContext()
        let entity = EntityNode(name: "Juan", summary: "A discussed person.", kind: .subject, embedding: [])
        XCTAssertEqual(entity.aliases, [])

        entity.aliases = ["Juan Gómez", "JG"]
        context.insert(entity)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<EntityNode>())
        XCTAssertEqual(fetched[0].aliases, ["Juan Gómez", "JG"])
    }

    func test_factEdge_supportsNilObjectID_andNilInvalidAt() throws {
        let context = try makeInMemoryContext()
        let subject = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        context.insert(subject)
        let fact = FactEdge(
            subjectID: subject.id, objectID: nil, predicate: "prefers",
            factText: "prefers concise replies", embedding: [0.5], validAt: Date()
        )
        context.insert(fact)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<FactEdge>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].objectID)
        XCTAssertNil(fetched[0].invalidAt)
    }
}
