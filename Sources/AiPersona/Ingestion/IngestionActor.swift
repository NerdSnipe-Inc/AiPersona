import Foundation
import os

/// One chat turn, formatted for extraction.
public struct ChatEpisode: Sendable {
    public let userText: String
    public let assistantText: String
    public let occurredAt: Date

    public init(userText: String, assistantText: String, occurredAt: Date) {
        self.userText = userText
        self.assistantText = assistantText
        self.occurredAt = occurredAt
    }
}

/// Background fact extraction + graph merge, invoked after each chat turn. `enqueue` is `async`
/// so callers control fire-and-forget vs. awaiting (tests await directly; a host app's production
/// call site wraps it in `Task { await ... }`) — a single local process needs no more than a
/// `Task`, no persistent job queue.
public actor IngestionActor {
    public static let shared = IngestionActor()

    private let logger = Logger(subsystem: "com.aipersona", category: "IngestionActor")

    public init() {}

    /// Extracts facts from `episode` via `provider`, merges/dedupes entities against `store`, and
    /// either adds a new active fact or invalidates a matching existing one (when `isCorrection`).
    /// Extraction failures are logged and skipped — never thrown further — since ingestion is a
    /// background enhancement that must never surface as a user-visible error.
    ///
    /// Returns the corrections that matched nothing to invalidate (`MemoryGraphStore.
    /// invalidateFacts` no-ops rather than guessing wrong). Previously this signal was silently
    /// dropped; a host app can now inspect the return value to surface e.g. "I'm not sure what to
    /// update" instead of the correction appearing to do nothing with no explanation.
    /// Pronouns a small on-device model sometimes extracts as a literal "subjectName"/"objectName"
    /// despite being told not to — a code-level backstop, not a substitute for the prompt fix
    /// (`ExtractionPromptFormat.instruction`), since prompt compliance on a 4-bit on-device model
    /// is never guaranteed.
    private static let pronouns: Set<String> = [
        "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself",
        "he", "him", "his", "she", "her", "hers", "they", "them", "their", "theirs",
        "we", "us", "our", "ours", "it", "its"
    ]

    /// Phrases that mark a fact as transient/self-evident (current date, current time) rather than
    /// a durable fact about the user — the exact failure mode that showed up in production as
    /// "The current date is Thursday, August 20, 2026." being saved as a permanent memory the
    /// moment `PersonaPromptBuilder.identityPreamble` started stating the date every turn.
    private static let transientMarkers = [
        "current date", "current time", "today's date", "the date is", "the time is", "o'clock"
    ]

    private static func isJunk(_ fact: ExtractedFact) -> Bool {
        if pronouns.contains(fact.subjectName.lowercased()) { return true }
        if let objectName = fact.objectName, pronouns.contains(objectName.lowercased()) { return true }
        let lowerText = fact.factText.lowercased()
        return Self.transientMarkers.contains { lowerText.contains($0) }
    }

    @discardableResult
    public func enqueue(
        _ episode: ChatEpisode, provider: MemoryProvider, store: MemoryGraphStore, knownUserName: String? = nil
    ) async -> [ExtractedFact] {
        let baseEpisodeText = "user: \(episode.userText)\nassistant: \(episode.assistantText)"
        let episodeText: String = if let knownUserName, !knownUserName.isEmpty {
            "Known user name: \(knownUserName)\n" + baseEpisodeText
        } else {
            baseEpisodeText
        }

        let facts: [ExtractedFact]
        do {
            facts = try await provider.extractFacts(fromEpisode: episodeText)
        } catch {
            logger.error("Extraction failed, skipping episode: \(error.localizedDescription)")
            return []
        }
        guard !facts.isEmpty else { return [] }
        let cleanFacts = facts.filter { !Self.isJunk($0) }
        guard !cleanFacts.isEmpty else { return [] }

        return await MainActor.run {
            _ = store.addEpisode(rawText: episodeText, summary: episodeText.prefix(200).description, occurredAt: episode.occurredAt)

            var failedCorrections: [ExtractedFact] = []
            for fact in cleanFacts {
                let subject = store.upsertEntity(
                    name: fact.subjectName, summary: fact.subjectName, kind: .user,
                    embedding: LocalEmbedder.embed(fact.subjectName)
                )
                let object = fact.objectName.map { objectName in
                    store.upsertEntity(name: objectName, summary: objectName, kind: .other, embedding: LocalEmbedder.embed(objectName))
                }

                let factEmbedding = LocalEmbedder.embed(fact.factText)
                if fact.isCorrection {
                    let didInvalidate = store.invalidateFacts(subjectID: subject.id, objectID: object?.id, relatedTo: factEmbedding)
                    if !didInvalidate {
                        logger.notice("Correction matched nothing to invalidate: \(fact.factText, privacy: .private)")
                        failedCorrections.append(fact)
                    }
                } else {
                    // No dedup in `addFact` itself — an exact-text repeat of an already-active fact
                    // for this subject is a no-op here rather than a second identical row.
                    let alreadyActive = store.activeFacts().contains {
                        $0.subjectID == subject.id && $0.factText.caseInsensitiveCompare(fact.factText) == .orderedSame
                    }
                    if !alreadyActive {
                        store.addFact(
                            subjectID: subject.id, objectID: object?.id, predicate: fact.predicate,
                            factText: fact.factText, embedding: factEmbedding
                        )
                    }
                }
            }
            return failedCorrections
        }
    }
}
