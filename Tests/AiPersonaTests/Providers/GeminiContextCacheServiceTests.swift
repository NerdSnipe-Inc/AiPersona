import XCTest
@testable import AiPersona

private actor StubGeminiCacheAPIClient: GeminiCacheAPIClient {
    var nameToReturn: String = "cachedContents/generated"
    var createCacheShouldThrow = false
    private(set) var createCacheCallCount = 0
    private(set) var refreshTTLCallCount = 0
    private(set) var lastRefreshedCacheName: String?

    func setCreateCacheShouldThrow(_ value: Bool) { createCacheShouldThrow = value }

    func createCache(model: String, systemPrompt: String, ttlSeconds: Int) async throws -> String {
        createCacheCallCount += 1
        if createCacheShouldThrow { throw GeminiCacheClientError.invalidResponse }
        return nameToReturn
    }

    func refreshTTL(cacheName: String, ttlSeconds: Int) async throws {
        refreshTTLCallCount += 1
        lastRefreshedCacheName = cacheName
    }
}

final class GeminiContextCacheServiceTests: XCTestCase {

    func test_cacheName_returnsNil_belowMinimumCacheableSize_withoutCallingClient() async {
        let service = GeminiContextCacheService(minimumCacheableCharacters: 100)
        let client = StubGeminiCacheAPIClient()

        let name = await service.cacheName(for: "short text", model: "gemini-2.5-flash", client: client)

        XCTAssertNil(name)
        let callCount = await client.createCacheCallCount
        XCTAssertEqual(callCount, 0)
    }

    func test_cacheName_createsCache_whenCompilationClearsTheSizeBar() async {
        let service = GeminiContextCacheService(minimumCacheableCharacters: 10)
        let client = StubGeminiCacheAPIClient()

        let name = await service.cacheName(for: "a compilation long enough to cache", model: "gemini-2.5-flash", client: client)

        XCTAssertEqual(name, "cachedContents/generated")
        let callCount = await client.createCacheCallCount
        XCTAssertEqual(callCount, 1)
    }

    func test_cacheName_reusesExistingCache_forTheSameCompilation_andRefreshesTTL() async {
        let service = GeminiContextCacheService(minimumCacheableCharacters: 10)
        let client = StubGeminiCacheAPIClient()
        let compilation = "a compilation long enough to cache"

        let first = await service.cacheName(for: compilation, model: "gemini-2.5-flash", client: client)
        let second = await service.cacheName(for: compilation, model: "gemini-2.5-flash", client: client)

        XCTAssertEqual(first, second)
        let createCount = await client.createCacheCallCount
        XCTAssertEqual(createCount, 1, "the second call for the same compilation must not create a new cache")
        let refreshCount = await client.refreshTTLCallCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_cacheName_createsNewCache_whenCompilationChanges() async {
        let service = GeminiContextCacheService(minimumCacheableCharacters: 10)
        let client = StubGeminiCacheAPIClient()

        _ = await service.cacheName(for: "first compilation long enough to cache", model: "gemini-2.5-flash", client: client)
        _ = await service.cacheName(for: "second, different compilation long enough to cache", model: "gemini-2.5-flash", client: client)

        let createCount = await client.createCacheCallCount
        XCTAssertEqual(createCount, 2)
    }

    func test_cacheName_returnsNil_whenCacheCreationFails_soCallerFallsBackToInlining() async {
        let service = GeminiContextCacheService(minimumCacheableCharacters: 10)
        let client = StubGeminiCacheAPIClient()
        await client.setCreateCacheShouldThrow(true)

        let name = await service.cacheName(for: "a compilation long enough to cache", model: "gemini-2.5-flash", client: client)

        XCTAssertNil(name)
    }
}
