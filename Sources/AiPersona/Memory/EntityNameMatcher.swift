import Foundation

/// Fuzzy entity-name matching for dedup ("Juan", "Juan Gómez", "JG" → one entity).
///
/// `LocalEmbedder`'s word-vector average was the originally planned approach, but proper nouns
/// like personal names generally have no entry in the general-English word-embedding vocabulary
/// (verified directly: "Juan", "Gómez", "JG", and "Maria" all embed to an empty vector), so
/// cosine similarity between two names is always 0 — embeddings cannot catch this case at all.
/// Token-level containment and initials matching are deterministic, need no embedding model, and
/// directly handle the motivating cases.
public enum EntityNameMatcher {

    /// True if `a` and `b` are likely the same entity: identical after diacritic/case folding,
    /// one name's tokens are a subset of the other's (e.g. "Juan" ⊆ {"juan", "gómez"}), or one
    /// name is the initials of the other's tokens (e.g. "JG" == initials of "Juan Gómez").
    public static func matches(_ a: String, _ b: String) -> Bool {
        let tokensA = tokens(of: a)
        let tokensB = tokens(of: b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }

        let setA = Set(tokensA)
        let setB = Set(tokensB)
        if setA == setB { return true }
        if setA.isSubset(of: setB) || setB.isSubset(of: setA) { return true }

        if tokensA.count == 1, tokensA[0] == initials(of: tokensB) { return true }
        if tokensB.count == 1, tokensB[0] == initials(of: tokensA) { return true }

        return false
    }

    private static func tokens(of name: String) -> [String] {
        name
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    private static func initials(of tokens: [String]) -> String {
        guard tokens.count > 1 else { return "" }
        return tokens.compactMap(\.first).map(String.init).joined()
    }
}
