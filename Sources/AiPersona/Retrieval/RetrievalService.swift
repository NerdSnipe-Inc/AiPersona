import Foundation

/// Two-layer retrieval mirroring synapse-cortex: a cached, session-level "compilation" (the
/// `factLimit` active facts ranked by subject-entity degree then recency, rebuilt only when a new
/// chat session starts) plus a per-turn hybrid-search top-up for anything not already in the
/// compilation. Facts beyond the budget are excluded from the compilation and become retrievable
/// via hybrid search on a later turn — this is what gives `perTurnMemoryBlock` real work to do.
/// `isCompilationExhaustive()` gates that per-turn work: when the graph is small enough that
/// nothing was excluded, the search is skipped rather than run against a guaranteed-empty pool.
@MainActor
public final class RetrievalService {
    public static let shared = RetrievalService(store: .shared)

    private let store: MemoryGraphStore
    private let factLimit: Int
    private var cachedCompilation: String?
    /// The live `store.activeFacts().count` at the moment `cachedCompilation` was built — the
    /// baseline `isCompilationExhaustive()` compares against to detect drift (facts added or
    /// invalidated since caching). Cached and cleared alongside `cachedCompilation`, never derived
    /// independently, so the two can never disagree about which snapshot they describe.
    private var cachedActiveFactCount: Int?

    public init(store: MemoryGraphStore, factLimit: Int = 20) {
        self.store = store
        self.factLimit = factLimit
    }

    public func startNewSession() {
        cachedCompilation = nil
        cachedActiveFactCount = nil
    }

    public func sessionCompilation() -> String {
        if let cachedCompilation { return cachedCompilation }
        let activeFacts = store.activeFacts()
        let degrees = EntityDegreeRanking.degrees(forActiveFacts: activeFacts)
        let facts = EntityDegreeRanking.rank(activeFacts, byDegrees: degrees)
            .prefix(factLimit)
            .map(\.factText)
        let compilation = facts.joined(separator: "\n")
        cachedCompilation = compilation
        cachedActiveFactCount = activeFacts.count
        return compilation
    }

    /// AiPersona's equivalent of synapse-cortex's `is_partial: false` short-circuit, which skips
    /// per-turn GraphRAG retrieval once hydration already covers the whole graph — `perTurnMemoryBlock`
    /// uses this to skip its own work entirely rather than run a hybrid search guaranteed to find
    /// nothing.
    ///
    /// True only when BOTH (a) the graph fit inside `factLimit` when `sessionCompilation()` was
    /// last cached — nothing was truncated out of it — AND (b) the live active-fact count still
    /// matches that cached snapshot exactly, i.e. nothing has been added or invalidated since.
    /// Condition (b) exists because `sessionCompilation()` is cached for the whole session, not
    /// recomputed per turn (see its doc comment); a fact ingested mid-session would be missing from
    /// the stale cached text while still being "active," so gating must fail closed — return
    /// `false`, meaning "search anyway" — the moment the live count drifts from the cached one,
    /// rather than risk hiding a real fact from retrieval just because the graph *used to* fit.
    /// Calling this computes `sessionCompilation()` first if this session hasn't cached one yet, so
    /// the two never disagree about which snapshot "exhaustive" is being asked about.
    public func isCompilationExhaustive() -> Bool {
        _ = sessionCompilation()
        guard let cachedActiveFactCount, cachedActiveFactCount <= factLimit else { return false }
        return store.activeFacts().count == cachedActiveFactCount
    }

    /// Runs hybrid search over active facts, excluding any whose text is already substring-present
    /// in `compilationText`, and returns a formatted memory block, or `nil` when nothing relevant
    /// is found. Gated by `isCompilationExhaustive()`: when the cached compilation already provably
    /// contains every active fact, skips the search entirely instead of computing it only to
    /// discover the candidate pool is empty.
    public func perTurnMemoryBlock(forQuery query: String, excluding compilationText: String, limit: Int = 5) -> String? {
        guard !isCompilationExhaustive() else { return nil }
        let candidateFacts = store.activeFacts().filter { !compilationText.contains($0.factText) }
        return Self.hybridSearchBlock(forQuery: query, over: candidateFacts, limit: limit)
    }

    /// Same as `perTurnMemoryBlock(forQuery:excluding:limit:)`, plus a reranking pass over the
    /// hybrid-search result — synapse-cortex's Gemini reranking feature (an opt-in overload rather
    /// than a parameter on the sync method, so this async, LLM-backed path can never be reached by
    /// accident; a host app must explicitly supply a `Reranker`). Falls back to the unreranked
    /// hybrid-search order if `reranker` returns something that isn't a faithful reordering of what
    /// it was given (wrong count, invented lines) — a broken/misbehaving reranker degrades to "no
    /// reranking," never to a corrupted or truncated memory block.
    public func perTurnMemoryBlock(forQuery query: String, excluding compilationText: String, limit: Int = 5, reranker: any Reranker) async -> String? {
        guard !isCompilationExhaustive() else { return nil }
        let candidateFacts = store.activeFacts().filter { !compilationText.contains($0.factText) }
        guard let block = Self.hybridSearchBlock(forQuery: query, over: candidateFacts, limit: limit) else { return nil }
        let lines = block.components(separatedBy: "\n")
        let reranked = await reranker.rerank(query: query, candidates: lines)
        guard Set(reranked) == Set(lines) else { return block }
        return reranked.joined(separator: "\n")
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
