import Foundation
import SwiftData

/// What kind of thing an `EntityNode` represents, generic across any host app's domain.
public enum EntityKind: String, Codable, Sendable {
    case user
    case subject
    case other
}

/// A node in the local memory graph. Mirrors synapse-cortex's Graphiti-backed `Entity` node.
@Model
public final class EntityNode: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var summary: String
    private var kindRaw: String
    /// L2-normalized embedding (see `LocalEmbedder`) — always computed locally regardless of
    /// which `MemoryProvider` performs extraction/chat, so the whole graph shares one embedding
    /// space.
    public var embedding: [Float]
    /// Alternate names fuzzy-resolved onto this entity (e.g. "Juan Gómez", "JG" → the "Juan"
    /// node), preserved rather than overwriting `name` so the original extracted name isn't lost.
    /// See `EntityNameMatcher`.
    public var aliases: [String]
    /// A generic, domain-agnostic identifier a host app can use to pin this entity to some
    /// external record (e.g. a CRM contact ID) — nil for entities with no external anchor
    /// (most chat-derived entities). Enables stable lookup via `MemoryGraphStore.findEntity(
    /// externalRef:)` instead of relying on fragile fuzzy name matching for identity that must
    /// never drift.
    public var externalRef: String?

    public var kind: EntityKind {
        get { EntityKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(), name: String, summary: String, kind: EntityKind, embedding: [Float],
        aliases: [String] = [], externalRef: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.kindRaw = kind.rawValue
        self.embedding = embedding
        self.aliases = aliases
        self.externalRef = externalRef
    }
}

/// A raw conversation episode fed into extraction. Mirrors synapse-cortex's `Episodic` node.
@Model
public final class EpisodicNode {
    @Attribute(.unique) public var id: UUID
    public var rawText: String
    public var summary: String
    public var occurredAt: Date

    public init(id: UUID = UUID(), rawText: String, summary: String, occurredAt: Date) {
        self.id = id
        self.rawText = rawText
        self.summary = summary
        self.occurredAt = occurredAt
    }
}

/// A bi-temporal fact edge. `invalidAt` is set by a correction rather than deleting the edge.
@Model
public final class FactEdge: Identifiable {
    @Attribute(.unique) public var id: UUID
    // SwiftData failed to build this model with multiple non-primary-key UUID properties on one
    // @Model class (verified directly: reverting to stored `UUID`/`UUID?` here did not compile).
    // Using String-backed storage as a workaround. The UUID values are always set via the computed
    // property setters, so the stored strings are guaranteed to be valid UUIDs; any parse failure
    // indicates data corruption.
    private var subjectIDString: String
    private var objectIDString: String?
    public var predicate: String
    public var factText: String
    public var embedding: [Float]
    public var validAt: Date
    public var invalidAt: Date?

    public var subjectID: UUID {
        get {
            guard let uuid = UUID(uuidString: subjectIDString) else {
                fatalError("FactEdge.subjectIDString is corrupted: '\(subjectIDString)' is not a valid UUID")
            }
            return uuid
        }
        set { subjectIDString = newValue.uuidString }
    }

    public var objectID: UUID? {
        get {
            guard let str = objectIDString else { return nil }
            guard let uuid = UUID(uuidString: str) else {
                fatalError("FactEdge.objectIDString is corrupted: '\(str)' is not a valid UUID")
            }
            return uuid
        }
        set { objectIDString = newValue?.uuidString }
    }

    public init(
        id: UUID = UUID(), subjectID: UUID, objectID: UUID?, predicate: String, factText: String,
        embedding: [Float], validAt: Date, invalidAt: Date? = nil
    ) {
        self.id = id
        self.subjectIDString = subjectID.uuidString
        self.objectIDString = objectID?.uuidString
        self.predicate = predicate
        self.factText = factText
        self.embedding = embedding
        self.validAt = validAt
        self.invalidAt = invalidAt
    }
}
