import Foundation

/// One entity as a `react-force-graph` node — synapse-cortex's feature 6 (Knowledge Graph
/// Visualization). No server or MCP agent needed: this is a pure mapping a host app can render
/// locally (SwiftUI/AppKit), unlike Notion export/import or Gemini caching.
public struct GraphVisualizationNode: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One fact edge between two entities, as a `react-force-graph` link. Facts with no `objectID`
/// (most personal facts, e.g. "User prefers dark mode") have no second entity to link to, so
/// they don't appear here — they're node-attribute-shaped, not graph-edge-shaped.
public struct GraphVisualizationLink: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let target: String
    public let label: String

    public init(source: String, target: String, label: String) {
        self.source = source
        self.target = target
        self.label = label
    }
}

public struct GraphVisualizationExport: Codable, Equatable, Sendable {
    public let nodes: [GraphVisualizationNode]
    public let links: [GraphVisualizationLink]

    public init(nodes: [GraphVisualizationNode], links: [GraphVisualizationLink]) {
        self.nodes = nodes
        self.links = links
    }

    /// `activeFacts` should already be temporally filtered (i.e. `MemoryGraphStore.activeFacts()`,
    /// not `allFacts()`) — this function does no filtering of its own beyond that.
    public static func build(fromEntities entities: [EntityNode], activeFacts: [FactEdge]) -> GraphVisualizationExport {
        let nodes = entities.map { GraphVisualizationNode(id: $0.id.uuidString, name: $0.name, kind: $0.kind.rawValue) }
        let links = activeFacts.compactMap { fact -> GraphVisualizationLink? in
            guard let objectID = fact.objectID else { return nil }
            return GraphVisualizationLink(source: fact.subjectID.uuidString, target: objectID.uuidString, label: fact.predicate)
        }
        return GraphVisualizationExport(nodes: nodes, links: links)
    }
}
