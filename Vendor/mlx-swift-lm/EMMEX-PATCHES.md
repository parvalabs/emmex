# emmex patches on top of upstream mlx-swift-lm

Vendored from https://github.com/ml-explore/mlx-swift-lm at `main` commit `ee673d6a`
(2026-09-22). Everything outside the items below is unchanged upstream code (MIT license).

## KV-cache reuse between requests (Libraries/MLXFoundationModels)

Upstream's FoundationModels adapter builds a fresh KV cache for every request, so a growing
transcript re-prefills all of its tokens on every turn (35 s at 6K tokens for an 8B model on an
M4). `PromptCacheReuse.swift` keeps several caches per model in a process-wide registry. For
each request it picks the cache sharing the longest prefix with the newly rendered prompt and
feeds only the suffix:

- When that cache is wholly a prefix of the prompt, it is extended in place.
- When only part of it matches (another session with the same system prompt), a trimmed copy is
  made, so the other session's tail survives the switch.
- An untrimmable cache (recurrent or rotating layers) with only a partial match gets a fresh
  cache instead.

Caches are evicted least recently used first, beyond 4 per model (`EMMEX_MLX_PROMPT_CACHES`) or
beyond 10% of RAM per model, at least 1 GB (`EMMEX_MLX_PROMPT_CACHE_MB`). The cache in use is
never evicted. When the host sets `MLXLanguageModel.promptCacheHeadroom` (emmex: available memory
minus a reserve), caches stop growing once it reaches zero and shrink to the one in use below it.
`MLXLanguageModel.promptCacheBytes` reports one model's total. Tests: `Tests/MLXFoundationModelsTests/PromptCacheReuseTests.swift`. Patched sites in `MLXLanguageModel.swift` are marked
`// emmex patch`: `runAllowedToolGeneration`, `runUnconstrained`, `runReasoning`, and the usage
emission in each so reported prompt tokens still count the whole prompt. `ModelCache.evictAll`
and `remove(modelID:)` drop the model's registry entries. Guided-JSON and required-tool paths are untouched
and still prefill everything.

Set `EMMEX_MLX_PROMPT_CACHE=0` to disable reuse.
