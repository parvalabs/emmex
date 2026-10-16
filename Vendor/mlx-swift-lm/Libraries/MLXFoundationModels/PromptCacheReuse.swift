// emmex patch: keep KV caches between requests so a growing transcript only prefills its new
// tail, and keep several per model so switching between sessions doesn't throw away the
// other session's prefix. See EMMEX-PATCHES.md at the package root.

#if FoundationModelsIntegration
#if canImport(FoundationModels, _version: 2)

import Foundation
import MLX
import MLXLMCommon

/// One cached conversation prefix. Touched only inside the model container's `perform`, which
/// serializes generation per model, so no lock of its own.
final class PromptCacheEntry: @unchecked Sendable {
    var cache: [KVCache] = []
    var tokens: [Int] = []          // the tokens `cache` represents, in order
    var lastUsed: UInt64 = 0
    var savedBlocks = 0             // leading blocks of `tokens` already on disk

    init(cache: [KVCache] = [], tokens: [Int] = []) { self.cache = cache; self.tokens = tokens }

    /// The ledger is trustworthy only when the cache holds exactly its tokens.
    var isConsistent: Bool { !tokens.isEmpty && cache.first?.offset == tokens.count }

    /// Approximate memory held by the cache arrays.
    var bytes: Int { cache.reduce(0) { $0 + $1.state.reduce(0) { $0 + $1.nbytes } } }
}

/// Process-wide registry of prompt caches, several per model, evicted least recently used
/// first when a model exceeds the entry count or byte budget.
final class PromptCacheRegistry: @unchecked Sendable {
    static let shared = PromptCacheRegistry()
    private let lock = NSLock()
    private var entries: [String: [PromptCacheEntry]] = [:]
    private var clock: UInt64 = 0

    private static let env = ProcessInfo.processInfo.environment
    /// Set through `MLXLanguageModel.promptCacheHeadroom`.
    nonisolated(unsafe) static var headroom: (@Sendable () -> Int)?
    /// `EMMEX_MLX_PROMPT_CACHE=0` turns reuse off (every request prefills everything).
    static let enabled: Bool = env["EMMEX_MLX_PROMPT_CACHE"] != "0"
    /// Cached prefixes kept per model (`EMMEX_MLX_PROMPT_CACHES`, default 4).
    static let maxEntries: Int = env["EMMEX_MLX_PROMPT_CACHES"].flatMap(Int.init).map { max(1, $0) } ?? 4
    /// Bytes all of one model's caches may hold (`EMMEX_MLX_PROMPT_CACHE_MB`, default 10% of RAM,
    /// at least 1 GB). The entry in use is kept even when it alone is over budget.
    static let maxBytes: Int = env["EMMEX_MLX_PROMPT_CACHE_MB"].flatMap(Int.init).map { $0 << 20 }
        ?? max(1 << 30, Int(ProcessInfo.processInfo.physicalMemory / 10))

    func entries(for modelID: String) -> [PromptCacheEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries[modelID] ?? []
    }

    /// Mark `entry` most recently used, registering it if new.
    func touch(_ entry: PromptCacheEntry, modelID: String) {
        lock.lock(); defer { lock.unlock() }
        clock += 1; entry.lastUsed = clock
        if !(entries[modelID] ?? []).contains(where: { $0 === entry }) { entries[modelID, default: []].append(entry) }
    }

    func drop(_ entry: PromptCacheEntry, modelID: String) {
        lock.lock(); defer { lock.unlock() }
        entries[modelID]?.removeAll { $0 === entry }
    }

    func bytes(for modelID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (entries[modelID] ?? []).reduce(0) { $0 + $1.bytes }
    }

    /// Evict least recently used entries other than `keeping` until the model is within budget.
    /// `headroom` is memory the system can still spare; when it runs out, caches shrink.
    func trim(modelID: String, keeping: PromptCacheEntry, maxEntries: Int = maxEntries, maxBytes: Int = maxBytes,
              headroom: Int? = PromptCacheRegistry.headroom?()) {
        lock.lock(); defer { lock.unlock() }
        var list = (entries[modelID] ?? []).sorted { $0.lastUsed < $1.lastUsed }
        var total = list.reduce(0) { $0 + $1.bytes }
        let budget = headroom.map { $0 >= maxBytes ? maxBytes : min(maxBytes, total + $0) } ?? maxBytes
        while list.count > 1, list.count > maxEntries || total > budget,
              let i = list.firstIndex(where: { $0 !== keeping }) {
            total -= list.remove(at: i).bytes
        }
        entries[modelID] = list
    }

    func remove(_ modelID: String) { lock.lock(); entries[modelID] = nil; lock.unlock() }
    func removeAll() { lock.lock(); entries.removeAll(); lock.unlock() }
}

@available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
extension MLXLanguageModel {
    /// emmex patch: bytes this model's prompt caches hold.
    public var promptCacheBytes: Int { PromptCacheRegistry.shared.bytes(for: modelID) }

    /// emmex patch: bytes the system can still spare for prompt caches. When it is zero or less,
    /// each model drops back to the cache in use. Unset means only the fixed budget applies.
    public static var promptCacheHeadroom: (@Sendable () -> Int)? {
        get { PromptCacheRegistry.headroom }
        set { PromptCacheRegistry.headroom = newValue }
    }
}

/// One request's reconciliation of the rendered prompt with the model's caches: which prefix is
/// reused, which suffix to feed, and how to update the ledger afterwards.
struct PromptCacheReuse {
    let modelID: String
    let entry: PromptCacheEntry
    let cache: [KVCache]
    let input: LMInput
    let promptTokens: [Int]
    let cachedCount: Int

    /// What to do with the cached entries for a prompt.
    enum Plan: Equatable {
        case fresh
        /// Extend entry `index` in place: it is a prefix of the prompt (after trimming `trim`
        /// tokens, which only happens when nothing else would be lost).
        case extend(index: Int, keep: Int)
        /// Copy entry `index` trimmed to `keep` tokens, leaving the original for its session.
        case branch(index: Int, keep: Int)
    }

    /// Choose the entry sharing the longest prefix with `tokens`. An entry that is wholly a
    /// prefix is extended in place; a partial match is copied when its cache can be trimmed, so
    /// the other session's tail survives.
    static func plan(tokens: [Int], cached: [(tokens: [Int], trimmable: Bool)]) -> Plan {
        guard tokens.count > 1 else { return .fresh }
        var best: (index: Int, common: Int)?
        for (i, c) in cached.enumerated() {
            let common = zip(tokens, c.tokens).prefix { $0 == $1 }.count
            if common > (best?.common ?? 0) { best = (i, common) }
        }
        guard let best else { return .fresh }
        // Always feed at least the last token so the model has something to sample from.
        let keep = min(best.common, tokens.count - 1)
        guard keep > 0 else { return .fresh }
        let c = cached[best.index]
        if keep == c.tokens.count { return .extend(index: best.index, keep: keep) }
        guard c.trimmable else { return .fresh }
        // The prompt repeats the whole entry but must feed its last token again: trimming one
        // token loses nothing another session needs.
        if best.common == c.tokens.count { return .extend(index: best.index, keep: keep) }
        return .branch(index: best.index, keep: keep)
    }

    /// Decide what to reuse. Text-only, rank-1, unmasked prompts qualify; anything else gets a
    /// fresh, unregistered cache and feeds the whole prompt.
    static func prepare(modelID: String, input: LMInput, model: any LanguageModel, parameters: GenerateParameters) throws -> PromptCacheReuse {
        let registry = PromptCacheRegistry.shared
        guard PromptCacheRegistry.enabled, input.image == nil, input.video == nil, input.audio == nil,
              input.text.mask == nil, input.text.tokens.ndim == 1 else {
            let cache = try model.newCache(parameters: parameters)
            return PromptCacheReuse(modelID: modelID, entry: PromptCacheEntry(cache: cache), cache: cache, input: input, promptTokens: [], cachedCount: 0)
        }
        let tokens = input.text.tokens.asArray(Int.self)
        let entries = registry.entries(for: modelID).filter { e in
            if !e.isConsistent { registry.drop(e, modelID: modelID) }
            return e.isConsistent
        }
        let plan = plan(tokens: tokens, cached: entries.map { ($0.tokens, canTrimPromptCache($0.cache)) })

        var entry: PromptCacheEntry
        var keep = 0
        let memoryKeep: Int
        switch plan {
        case .fresh: memoryKeep = 0
        case .extend(_, let k), .branch(_, let k): memoryKeep = k
        }
        // A longer prefix on disk (after an unload or a restart) beats a shorter one in memory.
        if let stored = PromptCacheDisk.storedBlocks(tokens, limit: tokens.count - 1, modelID: modelID),
           stored.hashes.count * PromptCacheDisk.blockSize > memoryKeep + PromptCacheDisk.blockSize,
           let cache = try? model.newCache(parameters: parameters),
           PromptCacheDisk.load(stored.hashes, dir: stored.dir, into: cache) {
            entry = PromptCacheEntry(cache: cache)
            keep = stored.hashes.count * PromptCacheDisk.blockSize
            entry.savedBlocks = stored.hashes.count
        } else {
            switch plan {
            case .fresh:
                entry = PromptCacheEntry(cache: try model.newCache(parameters: parameters))
            case .extend(let i, let k):
                entry = entries[i]; keep = k
                if k < entry.tokens.count { trimPromptCache(entry.cache, numTokens: entry.tokens.count - k) }
            case .branch(let i, let k):
                let source = entries[i]
                entry = PromptCacheEntry(cache: source.cache.map { $0.copy() })
                trimPromptCache(entry.cache, numTokens: source.tokens.count - k)
                entry.savedBlocks = source.savedBlocks
                keep = k
            }
            entry.savedBlocks = min(entry.savedBlocks, keep / PromptCacheDisk.blockSize)
        }
        if keep > 0, entry.cache.first?.offset != keep {
            // The trim did not land where the ledger says; start over rather than trust it.
            registry.drop(entry, modelID: modelID)
            entry = PromptCacheEntry(cache: try model.newCache(parameters: parameters)); keep = 0
        }
        entry.tokens = Array(tokens.prefix(keep))
        registry.touch(entry, modelID: modelID)
        registry.trim(modelID: modelID, keeping: entry)
        let fed = keep > 0 ? LMInput(tokens: MLXArray(Array(tokens[keep...]))) : input
        return PromptCacheReuse(modelID: modelID, entry: entry, cache: entry.cache, input: fed, promptTokens: tokens, cachedCount: keep)
    }

    /// After generation: the cache holds the prompt plus whatever the iterator fed (generated
    /// tokens, possibly one more than the consumer saw). Keep the part we can name, trim the rest.
    func commit(generated: [Int]) {
        guard !promptTokens.isEmpty, let offset = cache.first?.offset else { entry.tokens = []; return }
        let known = promptTokens + generated
        if offset == known.count {
            entry.tokens = known
        } else if offset > known.count, canTrimPromptCache(cache) {
            _ = trimPromptCache(cache, numTokens: offset - known.count)
            entry.tokens = cache.first?.offset == known.count ? known : []
        } else if offset < known.count, offset >= promptTokens.count {
            entry.tokens = Array(known.prefix(offset))
        } else {
            entry.tokens = []
        }
        PromptCacheDisk.save(entry, modelID: modelID)
    }

    /// Generation failed or was cancelled part-way: the ledger no longer describes the cache.
    func invalidate() { entry.tokens = [] }
}

#endif
#endif
