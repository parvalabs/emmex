// mlex patch: keep the KV cache between requests so a growing transcript only
// prefills its new tail. See MLEX-PATCHES.md at the package root.

#if FoundationModelsIntegration
#if canImport(FoundationModels, _version: 2)

import Foundation
import MLX
import MLXLMCommon

/// The cache one model carries between requests. Touched only inside the model container's
/// `perform`, which serializes generation per model, so no lock of its own.
final class PromptCacheEntry: @unchecked Sendable {
    var cache: [KVCache] = []
    var tokens: [Int] = []          // the tokens `cache` represents, in order
}

/// Process-wide registry of per-model prompt caches.
final class PromptCacheRegistry: @unchecked Sendable {
    static let shared = PromptCacheRegistry()
    private let lock = NSLock()
    private var entries: [String: PromptCacheEntry] = [:]

    /// `MLEX_MLX_PROMPT_CACHE=0` turns reuse off (every request prefills everything).
    static let enabled: Bool = ProcessInfo.processInfo.environment["MLEX_MLX_PROMPT_CACHE"] != "0"

    func entry(for modelID: String) -> PromptCacheEntry {
        lock.lock(); defer { lock.unlock() }
        if let e = entries[modelID] { return e }
        let e = PromptCacheEntry(); entries[modelID] = e; return e
    }
    func remove(_ modelID: String) { lock.lock(); entries[modelID] = nil; lock.unlock() }
    func removeAll() { lock.lock(); entries.removeAll(); lock.unlock() }
}

/// One request's reconciliation of the rendered prompt with the model's cache: which prefix is
/// reused, which suffix to feed, and how to update the ledger afterwards.
struct PromptCacheReuse {
    let entry: PromptCacheEntry
    let cache: [KVCache]
    let input: LMInput
    let promptTokens: [Int]
    let cachedCount: Int

    /// Decide what to reuse. Text-only, rank-1, unmasked prompts qualify; anything else gets a
    /// fresh cache and feeds the whole prompt (the previous behavior).
    static func prepare(modelID: String, input: LMInput, model: any LanguageModel, parameters: GenerateParameters) throws -> PromptCacheReuse {
        let entry = PromptCacheRegistry.shared.entry(for: modelID)
        func fresh() throws -> PromptCacheReuse {
            let cache = try model.newCache(parameters: parameters)
            entry.cache = cache; entry.tokens = []
            return PromptCacheReuse(entry: entry, cache: cache, input: input, promptTokens: [], cachedCount: 0)
        }
        guard PromptCacheRegistry.enabled, input.image == nil, input.video == nil, input.audio == nil,
              input.text.mask == nil, input.text.tokens.ndim == 1 else { return try fresh() }
        let tokens = input.text.tokens.asArray(Int.self)
        guard !entry.cache.isEmpty, !entry.tokens.isEmpty, tokens.count > 1 else {
            let r = try fresh(); return PromptCacheReuse(entry: entry, cache: r.cache, input: input, promptTokens: tokens, cachedCount: 0)
        }
        // The cache must hold exactly the ledger, or we cannot trust either.
        guard let offset = entry.cache.first?.offset, offset == entry.tokens.count else { return try withPrompt(fresh(), tokens) }
        let common = zip(tokens, entry.tokens).prefix { $0 == $1 }.count
        // Always feed at least the last token so the model has something to sample from.
        let keep = min(common, tokens.count - 1)
        guard keep > 0 else { return try withPrompt(fresh(), tokens) }
        if keep < entry.tokens.count {
            guard canTrimPromptCache(entry.cache) else { return try withPrompt(fresh(), tokens) }
            _ = trimPromptCache(entry.cache, numTokens: entry.tokens.count - keep)
            guard entry.cache.first?.offset == keep else { return try withPrompt(fresh(), tokens) }
        }
        entry.tokens = Array(tokens.prefix(keep))
        let suffix = LMInput(tokens: MLXArray(Array(tokens[keep...])))
        return PromptCacheReuse(entry: entry, cache: entry.cache, input: suffix, promptTokens: tokens, cachedCount: keep)
    }

    private static func withPrompt(_ r: PromptCacheReuse, _ tokens: [Int]) -> PromptCacheReuse {
        PromptCacheReuse(entry: r.entry, cache: r.cache, input: r.input, promptTokens: tokens, cachedCount: 0)
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
    }

    /// Generation failed or was cancelled part-way: the ledger no longer describes the cache.
    func invalidate() { entry.tokens = [] }
}

#endif
#endif
