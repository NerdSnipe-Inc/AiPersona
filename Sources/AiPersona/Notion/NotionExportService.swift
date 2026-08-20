import Foundation

/// Exports the memory graph's active facts to a Notion database — direct REST calls
/// (`api.notion.com/v1`), no MCP agent.
public enum NotionExportService {

    /// Pure mapping from graph state to export rows — no network. Facts whose subject entity
    /// isn't in `entities` are skipped (nothing meaningful to export without a subject name).
    public static func rows(fromEntities entities: [EntityNode], activeFacts: [FactEdge]) -> [NotionExportRow] {
        let entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        return activeFacts.compactMap { fact in
            guard let subject = entitiesByID[fact.subjectID] else { return nil }
            return NotionExportRow(
                subjectName: subject.name, kind: subject.kind.rawValue,
                factText: fact.factText, validFrom: fact.validAt
            )
        }
    }

    /// Creates a new database under `parentPageID` and populates it with one row per active
    /// fact, then returns the new database's ID. Re-running `export` creates another database
    /// rather than updating an existing one — this package doesn't track "the" export database
    /// across calls; a host app that wants incremental sync should persist the returned ID.
    @MainActor
    public static func export(store: MemoryGraphStore, client: any NotionAPIClient, parentPageID: String) async throws -> String {
        let databaseID = try await client.createDatabase(parentPageID: parentPageID)
        let rows = rows(fromEntities: store.allEntities(), activeFacts: store.activeFacts())
        for row in rows {
            try await client.createPage(databaseID: databaseID, row: row)
        }
        return databaseID
    }
}
