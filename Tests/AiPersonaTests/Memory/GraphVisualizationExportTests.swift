import XCTest
@testable import AiPersona

final class GraphVisualizationExportTests: XCTestCase {

    func test_build_mapsEntities_toNodes() {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let visa = EntityNode(name: "O-1 visa", summary: "A visa category.", kind: .subject, embedding: [])

        let export = GraphVisualizationExport.build(fromEntities: [user, visa], activeFacts: [])

        XCTAssertEqual(Set(export.nodes), Set([
            GraphVisualizationNode(id: user.id.uuidString, name: "User", kind: "user"),
            GraphVisualizationNode(id: visa.id.uuidString, name: "O-1 visa", kind: "subject")
        ]))
    }

    func test_build_mapsFactWithObject_toLink() {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let visa = EntityNode(name: "O-1 visa", summary: "A visa category.", kind: .subject, embedding: [])
        let fact = FactEdge(subjectID: user.id, objectID: visa.id, predicate: "wants", factText: "wants the O-1 visa", embedding: [], validAt: Date())

        let export = GraphVisualizationExport.build(fromEntities: [user, visa], activeFacts: [fact])

        XCTAssertEqual(export.links, [GraphVisualizationLink(source: user.id.uuidString, target: visa.id.uuidString, label: "wants")])
    }

    func test_build_excludesSubjectOnlyFacts_fromLinks_sinceThereIsNoSecondNode() {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let fact = FactEdge(subjectID: user.id, objectID: nil, predicate: "prefers", factText: "prefers dark mode", embedding: [], validAt: Date())

        let export = GraphVisualizationExport.build(fromEntities: [user], activeFacts: [fact])

        XCTAssertEqual(export.links, [])
    }

    func test_build_isCodable_toJSONMatchingReactForceGraphShape() throws {
        let user = EntityNode(name: "User", summary: "The app's user.", kind: .user, embedding: [])
        let export = GraphVisualizationExport.build(fromEntities: [user], activeFacts: [])

        let data = try JSONEncoder().encode(export)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["nodes"])
        XCTAssertNotNil(json["links"])
    }
}
