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
        guard let embedding else { return [] }
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var sum: [Double]?
        var count = 0
        for word in words {
            guard let vector = embedding.vector(for: word) else { continue }
            if sum == nil { sum = Array(repeating: 0, count: vector.count) }
            for i in 0..<vector.count { sum?[i] += vector[i] }
            count += 1
        }
        guard var averaged = sum, count > 0 else { return [] }
        for i in 0..<averaged.count { averaged[i] /= Double(count) }

        let magnitude = sqrt(averaged.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return averaged.map(Float.init) }
        return averaged.map { Float($0 / magnitude) }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return 0 }
        var dot: Double = 0
        for i in 0..<a.count { dot += Double(a[i]) * Double(b[i]) }
        return dot  // both vectors are already L2-normalized by `embed`, so dot product == cosine
    }
}
