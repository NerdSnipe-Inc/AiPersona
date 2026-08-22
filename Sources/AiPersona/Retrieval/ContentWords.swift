import Foundation

/// Small, deliberately conservative stopword list — only words common enough to appear in nearly
/// any English sentence regardless of topic. Not meant to be linguistically complete; it exists
/// solely to distinguish "shares/resolves a real topical word" from "shares/resolves a function
/// word like 'and' or 'how'". Shared by `HybridSearch` (lexical-overlap floor) and `LocalEmbedder`
/// (embedding-coverage fallback) — both need the same notion of "content word," and a query like
/// "How should webhook idempotency be handled?" only reveals its true OOV problem when coverage is
/// measured over {webhook, idempotency, handled}, not over all six words including four stopwords.
let contentWordStopwords: Set<String> = [
    "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "and", "or", "but",
    "if", "then", "of", "to", "in", "on", "for", "with", "by", "at", "from", "as", "that",
    "this", "these", "those", "it", "its", "should", "how", "what", "when", "where", "who",
    "which", "do", "does", "did", "not", "no", "you", "your", "i", "we", "they", "he", "she",
    "will", "can", "must", "may", "would", "could", "so", "than", "into", "about", "our",
]

func contentTerms(_ text: String) -> Set<String> {
    Set(
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !contentWordStopwords.contains($0) }
    )
}
