import Foundation

/// One extracted fact from a conversation episode. `isCorrection` is asked of the model directly
/// in the same extraction call. `objectName` is `nil` for subject-only facts.
public struct ExtractedFact: Codable, Sendable, Equatable {
    public let subjectName: String
    public let objectName: String?
    public let predicate: String
    public let factText: String
    public let isCorrection: Bool

    public init(subjectName: String, objectName: String?, predicate: String, factText: String, isCorrection: Bool) {
        self.subjectName = subjectName
        self.objectName = objectName
        self.predicate = predicate
        self.factText = factText
        self.isCorrection = isCorrection
    }
}

/// Performs entity/fact extraction from a chat episode. Embeddings are NOT part of this protocol
/// — every implementation's embeddings come from `LocalEmbedder` regardless of which provider
/// does extraction, keeping one consistent embedding space.
public protocol MemoryProvider: Sendable {
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact]
}

/// The JSON-array output format every `MemoryProvider` asks its underlying chat model to produce,
/// and the shared, defensive parser every implementation uses.
public enum ExtractionPromptFormat {
    public static let instruction = """
    Extract only facts, preferences, or relationships worth recalling in a FUTURE conversation — \
    durable information about the user or the people/things they mention, not everything that was \
    merely said. Skip: small talk, the assistant's own replies about itself, and anything \
    transient or self-evident that will be stale or meaningless later (the current date, the \
    current time, the weather, "it's currently X o'clock" style exchanges). If nothing meets that \
    bar, respond with an empty array: [] — an empty array is the correct, common answer, not a \
    fallback. Most turns produce zero facts; do not strain to find something to extract.

    Do NOT extract: greetings, thanks, acknowledgements ("ok", "got it", "sounds good"); the \
    user's questions themselves (a question is not a fact about the user); the user's momentary \
    emotional state or activity right now ("I'm tired", "I'm just browsing") unless they frame it \
    as a lasting trait or recurring pattern; anything the assistant said or offered to do; or a \
    restatement of something the episode already told you (a "Known user name: X" line is context, \
    not a fact to extract about X). If you are unsure whether something will matter next week, \
    leave it out — an omitted fact costs nothing, a wrong one pollutes memory permanently.

    Only name an entity in "subjectName"/"objectName" when the episode gives you something worth \
    recording about it — a preference, plan, attribute, or relationship. A name mentioned once in \
    passing with no attached information ("my coworker Sam said hi") is not itself a fact; do not \
    invent a thin fact just to justify creating that entity.

    Never use a pronoun ("I", "me", "my", "you", "he", "she", "they", "we") as "subjectName" or \
    "objectName" — a pronoun is not a name. If the user's real name is given at the start of this \
    episode as "Known user name: X", use X whenever they refer to themselves. Otherwise use "the \
    user" verbatim (not a pronoun) as a stand-in subject.

    Respond with ONLY a JSON array (no prose before or after) where each element has exactly these \
    fields: "subjectName" (string, never a pronoun), "objectName" (string or null, never a \
    pronoun), "predicate" (short string, e.g. "prefers", "works at", "no longer wants"), \
    "factText" (a full natural-language sentence stating the fact), and "isCorrection" (true if \
    this fact reverses or invalidates something previously said, false otherwise).
    """

    /// Extracts the first `[...]` JSON array substring from `modelOutput` (models sometimes wrap
    /// JSON in prose despite the instruction) and decodes it; returns `[]` on any failure rather
    /// than throwing, since a bad extraction call should never block or crash background
    /// ingestion.
    public static func parse(_ modelOutput: String) -> [ExtractedFact] {
        guard let start = modelOutput.firstIndex(of: "["),
              let end = modelOutput.lastIndex(of: "]"),
              start <= end
        else { return [] }
        let jsonSubstring = modelOutput[start...end]
        guard let data = String(jsonSubstring).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExtractedFact].self, from: data)) ?? []
    }
}
