// emmex patch: tests for keeping several prompt caches per model.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import MLXFoundationModels

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)

@Suite struct PromptCacheReusePlanTests {
    @Test func noEntriesIsFresh() {
        #expect(PromptCacheReuse.plan(tokens: [1, 2, 3], cached: []) == .fresh)
    }

    @Test func wholePrefixExtendsInPlace() {
        let plan = PromptCacheReuse.plan(tokens: [1, 2, 3, 4], cached: [([1, 2], true)])
        #expect(plan == .extend(index: 0, keep: 2))
    }

    @Test func picksLongestCommonPrefix() {
        let cached: [(tokens: [Int], trimmable: Bool)] = [([1, 9], true), ([1, 2, 3], true), ([7], true)]
        #expect(PromptCacheReuse.plan(tokens: [1, 2, 3, 4], cached: cached) == .extend(index: 1, keep: 3))
    }

    @Test func partialMatchBranchesSoTheOtherSessionSurvives() {
        // Session B shares the preamble [1, 2] with session A's cached [1, 2, 3, 4].
        let plan = PromptCacheReuse.plan(tokens: [1, 2, 8, 9], cached: [([1, 2, 3, 4], true)])
        #expect(plan == .branch(index: 0, keep: 2))
    }

    @Test func partialMatchOnUntrimmableCacheIsFresh() {
        #expect(PromptCacheReuse.plan(tokens: [1, 2, 8], cached: [([1, 2, 3], false)]) == .fresh)
    }

    @Test func identicalPromptTrimsOneTokenInPlace() {
        #expect(PromptCacheReuse.plan(tokens: [1, 2, 3], cached: [([1, 2, 3], true)]) == .extend(index: 0, keep: 2))
    }

    @Test func noSharedTokensIsFresh() {
        #expect(PromptCacheReuse.plan(tokens: [5, 6], cached: [([1, 2], true)]) == .fresh)
    }
}

@Suite struct PromptCacheRegistryTests {
    func entry(tokens: Int) -> PromptCacheEntry {
        let cache = KVCacheSimple()
        _ = cache.update(keys: MLXArray.zeros([1, 1, tokens, 4]), values: MLXArray.zeros([1, 1, tokens, 4]))
        return PromptCacheEntry(cache: [cache], tokens: Array(0 ..< tokens))
    }

    @Test func evictsLeastRecentlyUsedOverCount() {
        let registry = PromptCacheRegistry()
        let a = entry(tokens: 4), b = entry(tokens: 4), c = entry(tokens: 4)
        for e in [a, b, c] { registry.touch(e, modelID: "m") }
        registry.touch(a, modelID: "m")
        registry.trim(modelID: "m", keeping: c, maxEntries: 2, maxBytes: .max)
        #expect(Set(registry.entries(for: "m").map(ObjectIdentifier.init)) == Set([a, c].map(ObjectIdentifier.init)))
    }

    @Test func evictsOverBytesButKeepsTheEntryInUse() {
        let registry = PromptCacheRegistry()
        let a = entry(tokens: 8), b = entry(tokens: 8)
        registry.touch(a, modelID: "m"); registry.touch(b, modelID: "m")
        registry.trim(modelID: "m", keeping: a, maxEntries: 4, maxBytes: 1)
        #expect(registry.entries(for: "m").map(ObjectIdentifier.init) == [ObjectIdentifier(a)])
    }

    @Test func memoryPressureShrinksToTheEntryInUse() {
        let registry = PromptCacheRegistry()
        let a = entry(tokens: 8), b = entry(tokens: 8)
        registry.touch(a, modelID: "m"); registry.touch(b, modelID: "m")
        registry.trim(modelID: "m", keeping: b, maxEntries: 4, maxBytes: .max, headroom: 0)
        #expect(registry.entries(for: "m").count == 2)
        registry.trim(modelID: "m", keeping: b, maxEntries: 4, maxBytes: .max, headroom: -1)
        #expect(registry.entries(for: "m").map(ObjectIdentifier.init) == [ObjectIdentifier(b)])
    }

    @Test func branchCopyLeavesOriginalIntact() {
        let original = entry(tokens: 6)
        let copy = original.cache.map { $0.copy() }
        trimPromptCache(copy, numTokens: 4)
        #expect(copy.first?.offset == 2)
        #expect(original.cache.first?.offset == 6)
        #expect(original.isConsistent)
    }
}

#endif
