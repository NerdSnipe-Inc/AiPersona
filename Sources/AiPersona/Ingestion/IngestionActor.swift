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

/// A correction the model proposed that matched an existing active fact — but that fact (or, on
/// the object-scoped path, at least one fact in the matched set — see `enqueue`) is
/// `isUserEdited`, so `enqueue` did NOT invalidate it automatically. A host app surfaces this so
/// the user can Accept (most likely by calling `MemoryGraphStore.updateFact` with the corrected
/// text, or by invalidating `existingFact` and adding a replacement — either way `isUserEdited`
/// stays `true`, or the row becomes invalid; there is no API that clears it back to `false`) or
/// Discard (leave the hand-edited fact exactly as it is).
///
/// `existingFact` is a live SwiftData `@Model` reference (`FactEdge`), so despite this type being
/// marked `Sendable` to cross the `await MainActor.run { }` boundary inside `enqueue`, a
/// `PendingCorrection` must only be read or acted upon back on `@MainActor` — exactly where
/// `enqueue` constructs it and where `MemoryGraphStore`'s mutating APIs (e.g. to Accept/Discard)
/// must be called.
public struct PendingCorrection: Sendable {
    public let extractedFact: ExtractedFact
    public let existingFact: FactEdge

    public init(extractedFact: ExtractedFact, existingFact: FactEdge) {
        self.extractedFact = extractedFact
        self.existingFact = existingFact
    }
}

/// `enqueue`'s full outcome — see that method's doc comment.
public struct EnqueueResult: Sendable {
    public let failedCorrections: [ExtractedFact]
    public let pendingReviewCorrections: [PendingCorrection]

    /// True if EITHER `failedCorrections` or `pendingReviewCorrections` is non-empty — i.e. some
    /// part of this episode needs a human to look at it. Prefer this over spelling out the
    /// conjunction inline (`result.failedCorrections.isEmpty && result.pendingReviewCorrections
    /// .isEmpty`): a caller that checks only `failedCorrections` silently drops pending-review
    /// corrections, exactly the bug this property exists to make hard to reintroduce.
    public var needsHumanReview: Bool {
        !failedCorrections.isEmpty || !pendingReviewCorrections.isEmpty
    }

    public init(failedCorrections: [ExtractedFact], pendingReviewCorrections: [PendingCorrection]) {
        self.failedCorrections = failedCorrections
        self.pendingReviewCorrections = pendingReviewCorrections
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

    /// Cosine-similarity floor for "this is a reworded repeat of an already-active fact for the
    /// same subject," not just an exact-text repeat — production usage showed the same preference
    /// getting re-saved turn after turn with slightly different wording (e.g. "prefers dark mode"
    /// vs. "really likes dark mode"), which the exact-text-only check below this constant used to
    /// miss, one of the concrete ways memory accumulated useless duplicate points. Deliberately
    /// high: this must never merge two facts that are merely on the same TOPIC (e.g. two different
    /// visa preferences) as if they were the same fact — that's what `MemoryGraphStore
    /// .invalidateFacts`'s `minimumSimilarity: 0.5` is calibrated for (corrections, where a
    /// too-low match just no-ops and the correction is surfaced as failed); a false-positive here
    /// silently drops real information with no such signal. Calibrated against
    /// `LocalEmbedder`'s real word-vector averaging, not a round number: reworded restatements of
    /// the same preference measured ~0.89-0.90, unrelated facts sharing the same subject measured
    /// ~0.35 — 0.85 sits with wide margin below the former and far above the latter.
    private static let duplicateSimilarityThreshold: Double = 0.85

    /// True if `candidate` (already embedded as `candidateEmbedding`) is either an exact-text
    /// repeat of `active`, or similar enough per `duplicateSimilarityThreshold` to be the same
    /// fact restated — the two checks this replaces used to live inline in `enqueue`.
    private static func isDuplicate(_ active: FactEdge, ofFactText factText: String, embedding candidateEmbedding: [Float]) -> Bool {
        if active.factText.caseInsensitiveCompare(factText) == .orderedSame { return true }
        return LocalEmbedder.cosineSimilarity(active.embedding, candidateEmbedding) >= duplicateSimilarityThreshold
    }

    /// Extracts facts from `episode` via `provider`, merges/dedupes entities against `store`, and
    /// either adds a new active fact or invalidates a matching existing one (when `isCorrection`) —
    /// UNLESS that matching fact (or, on the object-scoped path, any fact in the matched set) is
    /// `isUserEdited`, in which case it/they are left untouched and the correction is instead
    /// reported via `EnqueueResult.pendingReviewCorrections`, so a host app can ask the user rather
    /// than silently overwriting a hand-authored/hand-edited fact. See `MemoryGraphStore
    /// .correctionCandidate`/`.correctionCandidates`'s doc comments for the underlying matching
    /// rules. Extraction failures are logged and skipped — never thrown further — since ingestion
    /// is a background enhancement that must never surface as a user-visible error.
    @discardableResult
    public func enqueue(
        _ episode: ChatEpisode, provider: MemoryProvider, store: MemoryGraphStore, knownUserName: String? = nil
    ) async -> EnqueueResult {
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
            return EnqueueResult(failedCorrections: [], pendingReviewCorrections: [])
        }
        guard !facts.isEmpty else { return EnqueueResult(failedCorrections: [], pendingReviewCorrections: []) }
        let cleanFacts = facts.filter { !Self.isJunk($0) }
        guard !cleanFacts.isEmpty else { return EnqueueResult(failedCorrections: [], pendingReviewCorrections: []) }

        return await MainActor.run {
            _ = store.addEpisode(rawText: episodeText, summary: episodeText.prefix(200).description, occurredAt: episode.occurredAt)

            var failedCorrections: [ExtractedFact] = []
            var pendingReviewCorrections: [PendingCorrection] = []
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
                    if let objectID = object?.id {
                        // Object-scoped: match the WHOLE set of active facts for this subject+
                        // object as one unit, not just one of them — see `correctionCandidates`'s
                        // doc comment for why a single `.first` match would be both a regression
                        // (leaving sibling facts active) and nondeterministic (which fact "wins"
                        // the isUserEdited check when several match).
                        let matches = store.correctionCandidates(subjectID: subject.id, objectID: objectID)
                        guard !matches.isEmpty else {
                            logger.notice("Correction matched nothing to invalidate: \(fact.factText, privacy: .private)")
                            failedCorrections.append(fact)
                            continue
                        }
                        if matches.contains(where: { $0.isUserEdited }) {
                            // Any protected fact in the set holds back the WHOLE set — invalidating
                            // just the non-protected ones would leave a confusing partial state.
                            for match in matches {
                                pendingReviewCorrections.append(PendingCorrection(extractedFact: fact, existingFact: match))
                            }
                        } else {
                            for match in matches { store.invalidateFact(id: match.id) }
                        }
                    } else {
                        guard let candidate = store.correctionCandidate(
                            subjectID: subject.id, relatedTo: factEmbedding
                        ) else {
                            logger.notice("Correction matched nothing to invalidate: \(fact.factText, privacy: .private)")
                            failedCorrections.append(fact)
                            continue
                        }
                        if candidate.isUserEdited {
                            pendingReviewCorrections.append(PendingCorrection(extractedFact: fact, existingFact: candidate))
                        } else {
                            store.invalidateFact(id: candidate.id)
                        }
                    }
                } else {
                    // No dedup in `addFact` itself — an exact-text OR near-duplicate (see
                    // `duplicateSimilarityThreshold`) repeat of an already-active fact for this
                    // subject is a no-op here rather than a second, redundant row.
                    let alreadyActive = store.activeFacts().contains {
                        $0.subjectID == subject.id && Self.isDuplicate($0, ofFactText: fact.factText, embedding: factEmbedding)
                    }
                    if !alreadyActive {
                        store.addFact(
                            subjectID: subject.id, objectID: object?.id, predicate: fact.predicate,
                            factText: fact.factText, embedding: factEmbedding
                        )
                    }
                }
            }
            return EnqueueResult(failedCorrections: failedCorrections, pendingReviewCorrections: pendingReviewCorrections)
        }
    }
}
