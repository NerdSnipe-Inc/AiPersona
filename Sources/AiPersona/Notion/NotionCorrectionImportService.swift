import Foundation

/// Reads corrections a user wrote into a Notion export database's "Correction Notes" column
/// (flagged via the "Needs Review" checkbox) and applies them back through the same correction
/// pipeline chat-turn corrections already use — `IngestionActor.enqueue`, not a separate agent,
/// since extraction/correction logic already exists and there's no reason to duplicate it.
public enum NotionCorrectionImportService {

    /// Returns the rows that still need a human to look at — mirrors `IngestionActor.enqueue`'s
    /// failed-correction and pending-review reporting so neither is silently cleared as if it had
    /// applied. A row is left flagged (its "Needs Review" checkbox untouched) when its correction
    /// either matched nothing to invalidate (`failedCorrections`) OR matched an existing
    /// `isUserEdited` fact that `enqueue` deliberately left alone (`pendingReviewCorrections`) —
    /// the latter is exactly "this needs a human decision," so clearing its flag would silently
    /// discard the one signal telling the user their hand-edited fact is being contested. Only a
    /// row whose correction fully applied has its "Needs Review" flag cleared.
    @MainActor
    public static func importCorrections(
        client: any NotionAPIClient, provider: MemoryProvider, store: MemoryGraphStore, databaseID: String
    ) async throws -> [NotionCorrectionRow] {
        let rows = try await client.queryNeedsReview(databaseID: databaseID)

        var failedRows: [NotionCorrectionRow] = []
        for row in rows {
            let episode = ChatEpisode(userText: row.correctionNotes, assistantText: "", occurredAt: Date())
            let result = await IngestionActor.shared.enqueue(episode, provider: provider, store: store)
            if !result.needsHumanReview {
                try await client.clearNeedsReview(pageID: row.pageID)
            } else {
                failedRows.append(row)
            }
        }
        return failedRows
    }
}
