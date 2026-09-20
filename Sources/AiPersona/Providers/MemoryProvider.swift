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

    /// Outcome of `parseDetailed` — lets a caller tell "the model correctly said nothing" apart
    /// from "the model said something we could not read", which `parse` alone cannot.
    public struct ParseResult: Sendable, Equatable {
        public let facts: [ExtractedFact]
        /// JSON objects that looked like facts but were unusable (missing required fields).
        public let skippedObjects: Int
        /// True if the output contained any JSON array/object at all (including `[]`).
        public let sawJSON: Bool
        /// True when non-empty output produced no facts and no JSON — i.e. probable garbage or
        /// a truncated/refused reply worth logging with the raw text.
        public var looksUnparseable: Bool { facts.isEmpty && !sawJSON }
    }

    /// Defensive parse of model output into facts; returns `[]` (never throws) since a bad
    /// extraction call must never block or crash background ingestion. See `parseDetailed`.
    public static func parse(_ modelOutput: String) -> [ExtractedFact] {
        parseDetailed(modelOutput).facts
    }

    /// Tolerant fact extraction. Handles, without losing the good elements: markdown fences,
    /// prose before/after, `<think>…</think>` blocks and any other bracket-bearing preamble, a
    /// bare object instead of an array, a `{"facts": [...]}` wrapper, output truncated mid-array
    /// (every COMPLETE object before the cut is kept), one malformed element among good ones,
    /// `null`/`"null"` objectName, and a missing/stringly-typed `isCorrection`.
    ///
    /// Works by scanning for balanced, string-aware `{…}` objects rather than trusting a single
    /// first-`[`-to-last-`]` slice (the old approach lost everything if the preamble contained a
    /// `[` or if any single element failed strict `Codable` decoding).
    public static func parseDetailed(_ modelOutput: String) -> ParseResult {
        let text = stripThinking(modelOutput)
        var facts: [ExtractedFact] = []
        var skipped = 0
        var sawJSON = text.contains("[]")
        // Bounded: brace matching is worst-case quadratic on pathological (runaway/garbage) output,
        // and a legitimate extraction reply is a few hundred tokens. 32k scalars is far beyond it.
        scanObjects(in: Array(text.unicodeScalars.prefix(maxScannedScalars))[...]) { object in
            sawJSON = true
            if let fact = fact(from: object) { facts.append(fact) } else { skipped += 1 }
        }
        return ParseResult(facts: facts, skippedObjects: skipped, sawJSON: sawJSON)
    }

    private static let maxScannedScalars = 32_768

    private static func stripThinking(_ text: String) -> String {
        var result = text
        // <think>…</think> (closed) and an unclosed <think>… (drop to end: it never answered).
        for (open, close) in [("<think>", "</think>"), ("<|channel>thought", "<channel|>")] {
            while let start = result.range(of: open) {
                if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                    result.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    result.removeSubrange(start.lowerBound..<result.endIndex)
                }
            }
        }
        return result
    }

    /// Calls `visit` with each top-level JSON object found (decoded). Objects that are not
    /// themselves facts but contain nested objects (e.g. a `{"facts":[…]}` wrapper) are
    /// descended into by `visit`'s caller via `fact(from:)` returning nil AND nested scanning here.
    private static func scanObjects(in scalars: ArraySlice<Unicode.Scalar>, visit: ([String: Any]) -> Void) {
        var i = scalars.startIndex
        while i < scalars.endIndex {
            guard scalars[i] == "{" else { i += 1; continue }
            guard let end = balancedEnd(of: scalars, from: i) else { i += 1; continue }
            let slice = String(String.UnicodeScalarView(scalars[i...end]))
            if let data = slice.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if object["subjectName"] != nil || object["factText"] != nil {
                    visit(object)
                    i = end + 1
                    continue
                }
                // A wrapper object (e.g. {"facts": [...]}) — look inside it.
                scanObjects(in: scalars[(i + 1)..<end], visit: visit)
                i = end + 1
                continue
            }
            // Invalid JSON inside balanced braces (trailing comma, single quotes…): try inside.
            scanObjects(in: scalars[(i + 1)..<end], visit: visit)
            i = end + 1
        }
    }

    /// Index of the `}` closing the `{` at `start`, honouring JSON strings/escapes; nil if the
    /// object never closes (truncated output).
    private static func balancedEnd(of scalars: ArraySlice<Unicode.Scalar>, from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < scalars.endIndex {
            let c = scalars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func fact(from object: [String: Any]) -> ExtractedFact? {
        guard let subject = (object["subjectName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty,
              let text = (object["factText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        var objectName = (object["objectName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = objectName, name.isEmpty || name.lowercased() == "null" || name.lowercased() == "none" {
            objectName = nil
        }
        let predicate = (object["predicate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isCorrection: Bool
        switch object["isCorrection"] {
        case let flag as Bool: isCorrection = flag
        case let word as String: isCorrection = word.lowercased() == "true"
        default: isCorrection = false
        }
        return ExtractedFact(
            subjectName: subject, objectName: objectName, predicate: predicate.isEmpty ? "states" : predicate,
            factText: text, isCorrection: isCorrection
        )
    }
}
