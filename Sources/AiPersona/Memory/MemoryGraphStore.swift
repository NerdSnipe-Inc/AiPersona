import Foundation
import SwiftData
import os

/// `@MainActor` wrapper around the local memory graph's own `ModelContainer`. Entity matching for
/// `upsertEntity` tries exact case-insensitive name match first, then fuzzy token/initials
/// matching via `EntityNameMatcher` (not embedding similarity — see that type's doc comment for
/// why word-vector embeddings can't resolve proper nouns).
@MainActor
public final class MemoryGraphStore {
    public static let shared = MemoryGraphStore()

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let logger = Logger(subsystem: "com.aipersona", category: "MemoryGraphStore")

    public init(inMemory: Bool = false) {
        let schema = Schema([EntityNode.self, EpisodicNode.self, FactEdge.self])
        do {
            let configuration = inMemory
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                : ModelConfiguration(schema: schema, url: Self.onDiskStoreURL())
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Memory graph container failed, falling back to in-memory: \(error.localizedDescription)")
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    /// A store file distinct from any host app's own SwiftData stores (e.g. a read-cache using the
    /// unqualified default `ModelContainer(for:)` URL) — sharing that default location between two
    /// containers with different, incompatible schemas corrupts both (verified: this was a real bug
    /// caught by a live app run, not a hypothetical). `"AiPersonaMemory.store"` under Application
    /// Support keeps this package's on-disk state fully isolated from whatever else the host app
    /// persists there.
    ///
    /// Namespaced under the host app's own bundle identifier: this package is meant to be reused
    /// across multiple host apps (Alric, AICompleteChat, ...), and `~/Library/Application Support`
    /// is the real, shared, unsandboxed folder on macOS unless the host app opts into App Sandbox —
    /// a bare `"AiPersonaMemory.store"` at that shared root would mean every unsandboxed host app
    /// on the same Mac reads and writes the exact same SQLite file, mixing their memory graphs.
    private static func onDiskStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "AiPersona"
        let hostDirectory = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let newURL = hostDirectory.appendingPathComponent("AiPersonaMemory.store")
        migrateFromUnnamespacedLocation(appSupport: appSupport, to: newURL)
        return newURL
    }

    /// One-time migration for installs that already have data at the old, unnamespaced path
    /// (`Application Support/AiPersonaMemory.store`, shared across every host app on the Mac) —
    /// moves the SQLite file and its `-shm`/`-wal` siblings so real existing memory isn't silently
    /// orphaned by the namespacing fix. No-ops once the new location exists or the old one doesn't.
    private static func migrateFromUnnamespacedLocation(appSupport: URL, to newURL: URL) {
        let oldURL = appSupport.appendingPathComponent("AiPersonaMemory.store")
        guard !FileManager.default.fileExists(atPath: newURL.path),
              FileManager.default.fileExists(atPath: oldURL.path)
        else { return }
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: oldURL.path + suffix)
            let destination = URL(fileURLWithPath: newURL.path + suffix)
            try? FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Resolves `name` against existing entities (exact match, then fuzzy — see
    /// `EntityNameMatcher`) before creating a new node, so "Juan" and "Juan Gómez" merge onto one
    /// entity instead of fragmenting into two. A fuzzy-matched `name` that isn't already the
    /// entity's canonical name is preserved as an alias rather than overwriting `name`, so the
    /// original extracted name is never lost.
    @discardableResult
    public func upsertEntity(name: String, summary: String, kind: EntityKind, embedding: [Float]) -> EntityNode {
        if let existing = findEntity(named: name) {
            existing.summary = summary
            existing.embedding = embedding
            try? context.save()
            return existing
        }
        if let existing = findEntity(fuzzyMatching: name) {
            existing.summary = summary
            if !existing.aliases.contains(name) {
                existing.aliases.append(name)
            }
            try? context.save()
            return existing
        }
        let entity = EntityNode(name: name, summary: summary, kind: kind, embedding: embedding)
        context.insert(entity)
        try? context.save()
        return entity
    }

    public func findEntity(named name: String) -> EntityNode? {
        let lowered = name.lowercased()
        return allEntities().first { entity in
            entity.name.lowercased() == lowered || entity.aliases.contains { $0.lowercased() == lowered }
        }
    }

    public func findEntity(fuzzyMatching name: String) -> EntityNode? {
        allEntities().first { entity in
            EntityNameMatcher.matches(name, entity.name)
                || entity.aliases.contains { EntityNameMatcher.matches(name, $0) }
        }
    }

    public func findEntity(externalRef: String) -> EntityNode? {
        allEntities().first { $0.externalRef == externalRef }
    }

    /// `externalRef`-first entity resolution: an exact `externalRef` match always wins (a stable ID
    /// beats fuzzy name matching for identity that must never drift), updating `name`/`summary`/
    /// `embedding` in place on a match. Falls back to the existing name/fuzzy-match resolution only
    /// when `externalRef` is nil or matches nothing yet (first call for a brand-new entity).
    @discardableResult
    public func upsertEntity(
        externalRef: String?, name: String, summary: String, kind: EntityKind, embedding: [Float]
    ) -> EntityNode {
        if let externalRef, let existing = findEntity(externalRef: externalRef) {
            existing.name = name
            existing.summary = summary
            existing.embedding = embedding
            try? context.save()
            return existing
        }
        let entity = upsertEntity(name: name, summary: summary, kind: kind, embedding: embedding)
        if let externalRef {
            entity.externalRef = externalRef
            try? context.save()
        }
        return entity
    }

    @discardableResult
    public func addFact(
        subjectID: UUID, objectID: UUID?, predicate: String, factText: String, embedding: [Float]
    ) -> FactEdge {
        let fact = FactEdge(
            subjectID: subjectID, objectID: objectID, predicate: predicate, factText: factText,
            embedding: embedding, validAt: Date()
        )
        context.insert(fact)
        try? context.save()
        return fact
    }

    /// Sets `invalidAt` on every currently-active fact matching `subjectID`/`predicate` — never
    /// deletes, per the bi-temporal design.
    public func invalidateFacts(subjectID: UUID, predicate: String, at date: Date = Date()) {
        let matching = activeFacts().filter { $0.subjectID == subjectID && $0.predicate == predicate }
        for fact in matching { fact.invalidAt = date }
        try? context.save()
    }

    /// Sets `invalidAt` on the currently-active fact(s) this correction is actually about —
    /// regardless of the exact predicate string. A correction is about "whatever this subject's
    /// relationship to this object/topic was," not literally the same predicate spelling (e.g.
    /// original predicate `"wants"`, correction predicate `"no longer wants"`), so exact predicate
    /// matching is too fragile for this case.
    ///
    /// When `objectID` is non-nil: matches subject+object exactly and invalidates every active fact
    /// that matches — this shape is already narrow (a distinct object entity scopes the correction
    /// unambiguously), so all matches are invalidated as before.
    ///
    /// When `objectID` is nil (the common "subject-only fact" case, like "User prefers X"): nearly
    /// all of a user's personal facts share the same subject entity, so blindly invalidating every
    /// active subject-only fact would silently wipe out unrelated facts (e.g. a correction about a
    /// visa preference would also invalidate an unrelated "prefers dark mode" fact). Instead, among
    /// active subject-only facts, invalidate only the SINGLE most semantically similar one to
    /// `correctionEmbedding` (by cosine similarity of `LocalEmbedder`-produced embeddings) — and
    /// only if it clears `minimumSimilarity`. If nothing clears the bar, invalidate nothing: an
    /// unrelated correction should silently no-op rather than guess wrong and destroy data.
    ///
    /// Never deletes, per the bi-temporal design.
    ///
    /// Returns whether anything was actually invalidated. The subject-only path can silently
    /// no-op (nothing clears `minimumSimilarity`) by design — the caller (e.g. `IngestionActor`)
    /// uses this to log or surface "I'm not sure what to update" instead of the failure being
    /// invisible.
    @discardableResult
    public func invalidateFacts(
        subjectID: UUID, objectID: UUID?, relatedTo correctionEmbedding: [Float],
        minimumSimilarity: Double = 0.5, at date: Date = Date()
    ) -> Bool {
        guard let objectID else {
            let candidates = activeFacts().filter { $0.subjectID == subjectID && $0.objectID == nil }
            let scored = candidates.map { ($0, LocalEmbedder.cosineSimilarity(correctionEmbedding, $0.embedding)) }
            guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= minimumSimilarity else { return false }
            best.0.invalidAt = date
            try? context.save()
            return true
        }

        let matching = activeFacts().filter { $0.subjectID == subjectID && $0.objectID == objectID }
        guard !matching.isEmpty else { return false }
        for fact in matching { fact.invalidAt = date }
        try? context.save()
        return true
    }

    /// Invalidates a single fact by its own `id` — the finer-grained counterpart to
    /// `invalidateFacts(subjectID:predicate:at:)`, which invalidates every active fact sharing
    /// that subject+predicate. Useful for a UI that lets a user "forget" one specific fact row
    /// without silently invalidating sibling facts under the same predicate (e.g. one of several
    /// active "task" facts). Returns `false` (no-op) if no active fact with that `id` exists.
    @discardableResult
    public func invalidateFact(id: UUID, at date: Date = Date()) -> Bool {
        guard let fact = allFacts().first(where: { $0.id == id && $0.invalidAt == nil }) else { return false }
        fact.invalidAt = date
        try? context.save()
        return true
    }

    @discardableResult
    public func addEpisode(rawText: String, summary: String, occurredAt: Date) -> EpisodicNode {
        let episode = EpisodicNode(rawText: rawText, summary: summary, occurredAt: occurredAt)
        context.insert(episode)
        try? context.save()
        return episode
    }

    public func activeFacts() -> [FactEdge] {
        allFacts().filter { $0.invalidAt == nil }
    }

    public func allFacts() -> [FactEdge] {
        (try? context.fetch(FetchDescriptor<FactEdge>())) ?? []
    }

    public func allEntities() -> [EntityNode] {
        (try? context.fetch(FetchDescriptor<EntityNode>())) ?? []
    }

    public func allEpisodes() -> [EpisodicNode] {
        (try? context.fetch(FetchDescriptor<EpisodicNode>())) ?? []
    }

    /// Edits an entity's canonical name and summary in place — the finer-grained counterpart to
    /// `upsertEntity`, for a UI that lets a user correct a mis-extracted name or summary directly
    /// rather than merging in a new upsert. Returns `false` (no-op) if no entity with that `id`
    /// exists.
    @discardableResult
    public func updateEntity(id: UUID, name: String, summary: String) -> Bool {
        guard let entity = allEntities().first(where: { $0.id == id }) else { return false }
        entity.name = name
        entity.summary = summary
        try? context.save()
        return true
    }

    /// Deletes a single entity and every fact edge that references it as subject or object — a
    /// hard delete, distinct from `invalidateFact`'s bi-temporal soft-delete, for a UI that lets a
    /// user remove an entity the extractor got wrong entirely rather than merely correcting it.
    /// Returns `false` (no-op) if no entity with that `id` exists.
    @discardableResult
    public func deleteEntity(id: UUID) -> Bool {
        guard let entity = allEntities().first(where: { $0.id == id }) else { return false }
        for fact in allFacts() where fact.subjectID == id || fact.objectID == id {
            context.delete(fact)
        }
        context.delete(entity)
        try? context.save()
        return true
    }

    /// Edits a fact's text in place — a direct correction, for a UI that lets a user fix a
    /// mis-extracted fact's wording without invalidating it and losing the edge's history. Use
    /// `invalidateFact` instead when the fact is simply wrong and should stop being active.
    /// Returns `false` (no-op) if no fact with that `id` exists.
    @discardableResult
    public func updateFact(id: UUID, factText: String) -> Bool {
        guard let fact = allFacts().first(where: { $0.id == id }) else { return false }
        fact.factText = factText
        try? context.save()
        return true
    }

    /// Deletes every entity, episode, and fact — irreversible. Used by a host app's "clear memory"
    /// settings action.
    public func deleteAll() {
        for entity in allEntities() { context.delete(entity) }
        for episode in allEpisodes() { context.delete(episode) }
        for fact in allFacts() { context.delete(fact) }
        try? context.save()
    }

    /// The current graph as `react-force-graph`-shaped nodes/links — synapse-cortex's Knowledge
    /// Graph Visualization feature. A host app renders this; this package stays headless.
    public func visualizationExport() -> GraphVisualizationExport {
        GraphVisualizationExport.build(fromEntities: allEntities(), activeFacts: activeFacts())
    }
}
