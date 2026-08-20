import Foundation

/// Two-layer retrieval mirroring synapse-cortex: a cached, session-level "compilation" (the most
/// recent `factLimit` active facts, rebuilt only when a new chat session starts) plus a per-turn
/// hybrid-search top-up for anything not already in the compilation. Facts beyond the budget are
/// excluded from the compilation and become retrievable via hybrid search on a later turn — this
/// is what gives `perTurnMemoryBlock` real work to do.
@MainActor
public final class RetrievalService {
    public static let shared = RetrievalService(store: .shared)

    private let store: MemoryGraphStore
    private let factLimit: Int
    private var cachedCompilation: String?

    public init(store: MemoryGraphStore, factLimit: Int = 20) {
        self.store = store
        self.factLimit = factLimit
    }

    public func startNewSession() {
        cachedCompilation = nil
    }

    public func sessionCompilation() -> String {
        if let cachedCompilation { return cachedCompilation }
        let facts = store.activeFacts()
            .sorted { $0.validAt > $1.validAt }
            .prefix(factLimit)
            .map(\.factText)
        let compilation = facts.joined(separator: "\n")
        cachedCompilation = compilation
        return compilation
    }

    /// Runs hybrid search over active facts, excluding any whose text is already substring-present
    /// in `compilationText`, and returns a formatted memory block, or `nil` when nothing relevant
    /// is found.
    public func perTurnMemoryBlock(forQuery query: String, excluding compilationText: String, limit: Int = 5) -> String? {
        let candidateFacts = store.activeFacts().filter { !compilationText.contains($0.factText) }
        return Self.hybridSearchBlock(forQuery: query, over: candidateFacts, limit: limit)
    }

    /// Hybrid-search over exactly one `predicate` slice of the graph, independent of
    /// `sessionCompilation()`/`perTurnMemoryBlock`'s contact-memory budget. Lets a host app ground
    /// answers in a static or reference knowledge base (e.g. a product-knowledge fact set) without
    /// that content competing with a growing pool of unrelated facts for the same top-K slots —
    /// see `perTurnMemoryBlock`'s doc comment for why that budget exists at all, and
    /// packs/ghl-core-v1/reviews/e4b-first-principles-pipeline-audit-2026-08-10.md (addendum
    /// 2026-08-18/19) for the concrete case this was added for. The package stays domain-agnostic:
    /// the caller supplies `predicate`, nothing here hardcodes what it means.
    public func predicateScopedBlock(forQuery query: String, predicate: String, limit: Int = 3) -> String? {
        let candidateFacts = store.activeFacts().filter { $0.predicate == predicate }
        return Self.hybridSearchBlock(forQuery: query, over: candidateFacts, limit: limit, requireLexicalOverlap: true)
    }

    /// `requireLexicalOverlap` drops any ranked result with zero non-stopword term overlap with
    /// the query before formatting the block. RRF fusion always returns *something* from a
    /// non-empty candidate pool even when nothing in it is actually relevant, because it only
    /// encodes relative rank; this is the floor that lets a caller distinguish "best available
    /// match" from "no real match." Applied only where a result gets framed to the model as
    /// ground truth to trust unconditionally (`predicateScopedBlock`); left off for
    /// `perTurnMemoryBlock`'s contact-memory retrieval, whose behavior under this floor hasn't
    /// been evaluated. See packs/ghl-core-v1/reviews/live-swift-retrieval-results-2026-08-20/
    /// README.md for the concrete misfire this targets: an SPF/DKIM/DMARC question pulled in an
    /// unrelated "document delivery" fact and the model treated it as authoritative, deflecting
    /// on a question it otherwise answered correctly.
    private static func hybridSearchBlock(
        forQuery query: String, over candidateFacts: [FactEdge], limit: Int, requireLexicalOverlap: Bool = false
    ) -> String? {
        guard !candidateFacts.isEmpty else { return nil }

        let documents = candidateFacts.map { EmbeddedDocument(id: $0.id, text: $0.factText, embedding: $0.embedding) }
        let queryEmbedding = LocalEmbedder.embed(query)
        var ranked = HybridSearch.searchScored(query: query, queryEmbedding: queryEmbedding, documents: documents, limit: limit)
        if requireLexicalOverlap {
            ranked = ranked.filter { $0.sharedContentTerms > 0 }
        }
        guard !ranked.isEmpty else { return nil }

        let factsByID = Dictionary(uniqueKeysWithValues: candidateFacts.map { ($0.id, $0) })
        let lines = ranked.compactMap { factsByID[$0.id]?.factText }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
