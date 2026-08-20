import Foundation

/// Reuses a Gemini `cachedContents` entry across chat turns within a session instead of
/// resending the full session compilation every time — synapse-cortex's Gemini Context Caching
/// feature (~75% input-token cost reduction on repeated turns).
///
/// Size-gated (below `minimumCacheableCharacters`, returns `nil` so the caller inlines the
/// compilation instead — Gemini has a minimum cacheable size, and caching a tiny prefix isn't
/// worth the extra round trip). On a cache hit for the same compilation, refreshes the cache's
/// TTL — awaited (not fire-and-forget, unlike the source's server implementation) since this
/// package has no per-request latency budget to protect and an awaited call is simpler to reason
/// about and test deterministically. On cache-creation failure, returns `nil` — the "transparent
/// fallback" is the caller choosing to inline the full compilation instead of using a cache name,
/// not a retry loop inside this service.
public actor GeminiContextCacheService {
    public static let shared = GeminiContextCacheService()

    private let minimumCacheableCharacters: Int
    private let ttlSeconds: Int
    private var cacheName: String?
    private var cachedCompilation: String?

    public init(minimumCacheableCharacters: Int = 4000, ttlSeconds: Int = 3600) {
        self.minimumCacheableCharacters = minimumCacheableCharacters
        self.ttlSeconds = ttlSeconds
    }

    /// Clears any tracked cache reference — call when a chat session ends, alongside
    /// `RetrievalService.startNewSession()`, so a new session doesn't reuse a stale cache name.
    public func reset() {
        cacheName = nil
        cachedCompilation = nil
    }

    public func cacheName(for compilation: String, model: String, client: any GeminiCacheAPIClient) async -> String? {
        guard compilation.count >= minimumCacheableCharacters else { return nil }

        if compilation == cachedCompilation, let existingName = cacheName {
            try? await client.refreshTTL(cacheName: existingName, ttlSeconds: ttlSeconds)
            return existingName
        }

        guard let name = try? await client.createCache(model: model, systemPrompt: compilation, ttlSeconds: ttlSeconds) else {
            return nil
        }
        cacheName = name
        cachedCompilation = compilation
        return name
    }
}
