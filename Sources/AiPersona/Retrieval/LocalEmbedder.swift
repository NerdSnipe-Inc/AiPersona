import Foundation
import NaturalLanguage

/// On-device, zero-setup semantic embedding: averages `NLEmbedding.wordEmbedding(for: .english)`
/// vectors across a text's words, L2-normalized. Used for ALL memory embeddings regardless of
/// which `MemoryProvider` performs extraction/chat generation — one consistent embedding space
/// avoids needing to re-embed the whole graph on a provider switch (and Anthropic has no
/// embeddings API at all, so per-provider embeddings isn't viable anyway). Word-vector averaging
/// is coarser than a purpose-built sentence-embedding model, but BM25 (Task 7) carries most of
/// hybrid search's precision — sufficient to fuse with it via RRF (Task 9).
public enum LocalEmbedder {
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    public static func embed(_ text: String) -> [Float] {
        embedWithCoverage(text).vector
    }

    /// Same averaging as `embed(_:)`, but also reports what fraction of the text's *content* words
    /// (non-stopword — see `contentWordStopwords`) actually resolved to a vector —
    /// `NLEmbedding.wordEmbedding(for: .english)` silently returns `nil` for out-of-vocabulary
    /// words (verified directly: "spf", "dkim", "dmarc", "webhook", and "idempotency" all resolve
    /// to nothing), so a short technical query can end up embedded from only its generic leftover
    /// words while looking like a normal, fully-resolved vector to any caller that only reads
    /// `.vector`. Deliberately measured over content words only, not all words: "How should webhook
    /// idempotency be handled?" is 4/6 stopwords ("how", "should", "be" + one resolving content
    /// word), so a naive whole-query fraction (0.67) stays misleadingly high even though the
    /// query's only two topical words are both unresolved — measured directly, that version let a
    /// near-uniform ~0.75-0.78 similarity to nearly every document in the corpus drown out BM25's
    /// correct #1 ranking for "webhook idempotency" entirely. `resolvedFraction` is what lets a
    /// caller (`HybridSearch.searchScored`) detect the real case and stop trusting the embedding
    /// signal for it — see that file's `queryEmbeddingCoverage` parameter.
    public static func embedWithCoverage(_ text: String) -> (vector: [Float], resolvedFraction: Double) {
        guard let embedding else { return ([], 0) }
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return ([], 0) }

        let contentWords = words.filter { !contentWordStopwords.contains($0) }

        var sum: [Double]?
        var count = 0
        for word in words {
            guard let vector = embedding.vector(for: word) else { continue }
            if sum == nil { sum = Array(repeating: 0, count: vector.count) }
            for i in 0..<vector.count { sum?[i] += vector[i] }
            count += 1
        }
        let resolvedContentCount = contentWords.filter { embedding.vector(for: $0) != nil }.count
        // A query that's entirely stopwords (no content words at all) has nothing to measure OOV
        // coverage against — treat it as fully "covered" rather than manufacturing a 0/0 signal
        // that would spuriously trigger the fallback for an all-generic query.
        let resolvedFraction = contentWords.isEmpty ? 1.0 : Double(resolvedContentCount) / Double(contentWords.count)
        guard var averaged = sum, count > 0 else { return ([], resolvedFraction) }
        for i in 0..<averaged.count { averaged[i] /= Double(count) }

        let magnitude = sqrt(averaged.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return (averaged.map(Float.init), resolvedFraction) }
        return (averaged.map { Float($0 / magnitude) }, resolvedFraction)
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return 0 }
        var dot: Double = 0
        for i in 0..<a.count { dot += Double(a[i]) * Double(b[i]) }
        return dot  // both vectors are already L2-normalized by `embed`, so dot product == cosine
    }
}
