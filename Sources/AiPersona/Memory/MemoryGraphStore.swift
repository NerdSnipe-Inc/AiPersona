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
    private let logger = AiPersonaLog.logger("Store")

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
        do {
            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        } catch {
            AiPersonaLog.logger("Store").error("Cannot create store directory \(hostDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
            if FileManager.default.fileExists(atPath: source.path) {
                do { try FileManager.default.moveItem(at: source, to: destination) } catch {
                    AiPersonaLog.logger("Store").error("Legacy store migration failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
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
            persist()
            return existing
        }
        if let existing = findEntity(fuzzyMatching: name) {
            existing.summary = summary
            if !existing.aliases.contains(name) {
                existing.aliases.append(name)
            }
            persist()
            return existing
        }
        let entity = EntityNode(name: name, summary: summary, kind: kind, embedding: embedding)
        context.insert(entity)
        persist()
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
            persist()
            return existing
        }
        let entity = upsertEntity(name: name, summary: summary, kind: kind, embedding: embedding)
        if let externalRef {
            entity.externalRef = externalRef
            persist()
        }
        return entity
    }

    @discardableResult
    public func addFact(
        subjectID: UUID, objectID: UUID?, predicate: String, factText: String, embedding: [Float],
        isUserEdited: Bool = false
    ) -> FactEdge {
        let fact = FactEdge(
            subjectID: subjectID, objectID: objectID, predicate: predicate, factText: factText,
            embedding: embedding, validAt: Date(), isUserEdited: isUserEdited
        )
        context.insert(fact)
        persist()
        return fact
    }

    /// Sets `invalidAt` on every currently-active fact matching `subjectID`/`predicate` — never
    /// deletes, per the bi-temporal design.
    public func invalidateFacts(subjectID: UUID, predicate: String, at date: Date = Date()) {
        let matching = activeFacts().filter { $0.subjectID == subjectID && $0.predicate == predicate }
        for fact in matching { fact.invalidAt = date }
        persist()
    }

    /// Finds the single active fact that a subject-only correction (`relatedTo` its embedding) is
    /// actually about, using the exact same cosine-similarity matching rule
    /// `invalidateFacts(subjectID:objectID:relatedTo:...)` uses on its `objectID == nil` path —
    /// extracted here as a read-only lookup so a caller (e.g. `IngestionActor`) can inspect the
    /// match (in particular, whether it's `isUserEdited`) BEFORE deciding whether to actually
    /// invalidate it. Never mutates. See `invalidateFacts(subjectID:objectID:relatedTo:...)`'s own
    /// (now-delegating) doc comment for the full matching-rule rationale.
    ///
    /// For the object-scoped case, see `correctionCandidates(subjectID:objectID:)` instead — that
    /// path doesn't need scoring, since an explicit object narrows the match exactly.
    public func correctionCandidate(
        subjectID: UUID, relatedTo correctionEmbedding: [Float], minimumSimilarity: Double = 0.5
    ) -> FactEdge? {
        let candidates = activeFacts().filter { $0.subjectID == subjectID && $0.objectID == nil }
        let scored = candidates.map { ($0, LocalEmbedder.cosineSimilarity(correctionEmbedding, $0.embedding)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= minimumSimilarity else { return nil }
        return best.0
    }

    /// Finds EVERY active fact matching `subjectID`+`objectID` exactly — the object-scoped
    /// counterpart to `correctionCandidate(subjectID:relatedTo:minimumSimilarity:)`. Unlike that
    /// subject-only path, this doesn't need cosine-similarity scoring: an explicit object narrows
    /// the match exactly, so this is a plain filter over `activeFacts()`. Deliberately ignores any
    /// notion of `relatedTo`/`minimumSimilarity` — every fact sharing this exact subject+object is
    /// considered a match regardless of how similar its text is to the correction.
    ///
    /// Returns the WHOLE match set (not just one) so a caller can treat it as a single unit — e.g.
    /// `IngestionActor.enqueue` checks whether ANY fact in the set is `isUserEdited` before
    /// invalidating any of them, rather than picking one arbitrarily. Never mutates.
    public func correctionCandidates(subjectID: UUID, objectID: UUID) -> [FactEdge] {
        activeFacts().filter { $0.subjectID == subjectID && $0.objectID == objectID }
    }

    /// Sets `invalidAt` on the currently-active fact(s) this correction is actually about —
    /// regardless of the exact predicate string. A correction is about "whatever this subject's
    /// relationship to this object/topic was," not literally the same predicate spelling (e.g.
    /// original predicate `"wants"`, correction predicate `"no longer wants"`), so exact predicate
    /// matching is too fragile for this case. Matching itself lives in `correctionCandidate(
    /// subjectID:relatedTo:minimumSimilarity:)` (subject-only) and `correctionCandidates(
    /// subjectID:objectID:)` (object-scoped), which this delegates to — see those methods' doc
    /// comments for the full matching-rule rationale.
    ///
    /// When `objectID` is non-nil, EVERY currently-active fact matching subject+object is
    /// invalidated (that shape is already narrow enough this stays safe) — this does NOT duplicate
    /// `correctionCandidates`'s matching logic, it calls it directly.
    ///
    /// Never deletes, per the bi-temporal design. Returns whether anything was actually
    /// invalidated — the subject-only path can silently no-op (nothing clears
    /// `minimumSimilarity`) by design.
    @discardableResult
    public func invalidateFacts(
        subjectID: UUID, objectID: UUID?, relatedTo correctionEmbedding: [Float],
        minimumSimilarity: Double = 0.5, at date: Date = Date()
    ) -> Bool {
        guard let objectID else {
            guard let candidate = correctionCandidate(
                subjectID: subjectID, relatedTo: correctionEmbedding, minimumSimilarity: minimumSimilarity
            ) else { return false }
            candidate.invalidAt = date
            persist()
            return true
        }

        let matching = correctionCandidates(subjectID: subjectID, objectID: objectID)
        guard !matching.isEmpty else { return false }
        for fact in matching { fact.invalidAt = date }
        persist()
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
        persist()
        return true
    }

    @discardableResult
    public func addEpisode(rawText: String, summary: String, occurredAt: Date) -> EpisodicNode {
        let episode = EpisodicNode(rawText: rawText, summary: summary, occurredAt: occurredAt)
        context.insert(episode)
        persist()
        return episode
    }

    /// Save failures used to be swallowed by `try?`, leaving an in-memory graph that silently
    /// diverged from disk. They are now logged (subsystem `cc.nerdsnipe.AiPersona`, category
    /// `Store`) — the mutating APIs stay non-throwing so existing hosts keep compiling.
    private func persist() {
        do { try context.save() } catch {
            logger.error("SwiftData save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        do { return try context.fetch(FetchDescriptor<T>()) } catch {
            logger.error("SwiftData fetch of \(String(describing: type), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func activeFacts() -> [FactEdge] {
        allFacts().filter { $0.invalidAt == nil }
    }

    public func allFacts() -> [FactEdge] {
        fetchAll(FactEdge.self)
    }

    public func allEntities() -> [EntityNode] {
        fetchAll(EntityNode.self)
    }

    public func allEpisodes() -> [EpisodicNode] {
        fetchAll(EpisodicNode.self)
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
        persist()
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
        persist()
        return true
    }

    /// Edits a fact's text in place — a direct correction, for a UI that lets a user fix a
    /// mis-extracted fact's wording without invalidating it and losing the edge's history. Always
    /// marks the fact `isUserEdited` — an edit is unambiguously a human action, and this is the
    /// signal `IngestionActor.enqueue` uses to stop auto-merging future AI corrections onto it. Use
    /// `invalidateFact` instead when the fact is simply wrong and should stop being active.
    /// Returns `false` (no-op) if no fact with that `id` exists.
    @discardableResult
    public func updateFact(id: UUID, factText: String) -> Bool {
        guard let fact = allFacts().first(where: { $0.id == id }) else { return false }
        fact.factText = factText
        fact.isUserEdited = true
        persist()
        return true
    }

    /// Deletes every entity, episode, and fact — irreversible. Used by a host app's "clear memory"
    /// settings action.
    public func deleteAll() {
        for entity in allEntities() { context.delete(entity) }
        for episode in allEpisodes() { context.delete(episode) }
        for fact in allFacts() { context.delete(fact) }
        persist()
    }

    /// The current graph as `react-force-graph`-shaped nodes/links — synapse-cortex's Knowledge
    /// Graph Visualization feature. A host app renders this; this package stays headless.
    public func visualizationExport() -> GraphVisualizationExport {
        GraphVisualizationExport.build(fromEntities: allEntities(), activeFacts: activeFacts())
    }
}
