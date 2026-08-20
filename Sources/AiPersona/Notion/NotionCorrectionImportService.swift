import Foundation

/// Reads corrections a user wrote into a Notion export database's "Correction Notes" column
/// (flagged via the "Needs Review" checkbox) and applies them back through the same correction
/// pipeline chat-turn corrections already use — `IngestionActor.enqueue`, not a separate agent,
/// since extraction/correction logic already exists and there's no reason to duplicate it.
public enum NotionCorrectionImportService {

    /// Returns the rows whose correction matched nothing to invalidate — mirrors
    /// `IngestionActor.enqueue`'s failed-correction reporting so these aren't silently cleared as
    /// if they'd applied. Successfully applied rows have their
    /// "Needs Review" flag cleared; failed rows are left as-is for a user to revisit.
    @MainActor
    public static func importCorrections(
        client: any NotionAPIClient, provider: MemoryProvider, store: MemoryGraphStore, databaseID: String
    ) async throws -> [NotionCorrectionRow] {
        let rows = try await client.queryNeedsReview(databaseID: databaseID)

        var failedRows: [NotionCorrectionRow] = []
        for row in rows {
            let episode = ChatEpisode(userText: row.correctionNotes, assistantText: "", occurredAt: Date())
            let failedCorrections = await IngestionActor.shared.enqueue(episode, provider: provider, store: store)
            if failedCorrections.isEmpty {
                try await client.clearNeedsReview(pageID: row.pageID)
            } else {
                failedRows.append(row)
            }
        }
        return failedRows
    }
}
