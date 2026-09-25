# emlex patches on top of upstream mlx-swift-lm

Vendored from https://github.com/ml-explore/mlx-swift-lm at `main` commit `ee673d6a`
(2026-09-22). Everything outside the items below is unchanged upstream code (MIT license).

## KV-cache reuse between requests (Libraries/MLXFoundationModels)

Upstream's FoundationModels adapter builds a fresh KV cache for every request, so a growing
transcript re-prefills all of its tokens on every turn (35 s at 6K tokens for an 8B model on an
M4). `PromptCacheReuse.swift` keeps one cache per model in a process-wide registry, compares the
newly rendered prompt with the tokens the cache represents, trims the cache back to the common
prefix and feeds only the suffix. Patched sites in `MLXLanguageModel.swift` are marked
`// emlex patch`: `runAllowedToolGeneration`, `runUnconstrained`, `runReasoning`, and the usage
emission in each so reported prompt tokens still count the whole prompt. `ModelCache.evictAll`
and `remove(modelID:)` drop the registry entry. Guided-JSON and required-tool paths are untouched
and still prefill everything.

Set `EMLEX_MLX_PROMPT_CACHE=0` to disable reuse.
