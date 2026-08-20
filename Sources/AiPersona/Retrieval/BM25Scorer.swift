import Foundation

/// A single scorable document (an `EntityNode.summary` or `FactEdge.factText`).
public struct BM25Document {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// Standard BM25, computed fresh over the full active-fact/entity set each call — no persistent
/// inverted index. At personal-assistant scale this is fast enough; a persistent index is a
/// future optimization if profiling ever shows otherwise.
public enum BM25Scorer {
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func score(
        query: String, documents: [BM25Document], k1: Double = 1.2, b: Double = 0.75
    ) -> [(id: UUID, score: Double)] {
        guard !documents.isEmpty else { return [] }

        let queryTerms = Set(tokenize(query))
        guard !queryTerms.isEmpty else { return documents.map { (id: $0.id, score: 0) } }

        let tokenizedDocs = documents.map { (id: $0.id, terms: tokenize($0.text)) }
        let docLengths = tokenizedDocs.map { Double($0.terms.count) }
        let avgDocLength = docLengths.reduce(0, +) / Double(max(docLengths.count, 1))
        let docCount = Double(tokenizedDocs.count)

        var documentFrequency: [String: Int] = [:]
        for term in queryTerms {
            documentFrequency[term] = tokenizedDocs.filter { $0.terms.contains(term) }.count
        }

        return tokenizedDocs.enumerated().map { index, doc in
            let docLength = docLengths[index]
            var score = 0.0
            for term in queryTerms {
                let termFrequency = Double(doc.terms.filter { $0 == term }.count)
                guard termFrequency > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(((docCount - df + 0.5) / (df + 0.5)) + 1)
                let numerator = termFrequency * (k1 + 1)
                let denominator = termFrequency + k1 * (1 - b + b * (docLength / avgDocLength))
                score += idf * (numerator / denominator)
            }
            return (id: doc.id, score: max(score, 0))
        }
    }
}
