# mlex feasibility spikes

Goal: a Swift agent harness on Apple's FoundationModels framework (macOS 27) that routes
each turn between the on-device model, an open local model, Private Cloud Compute, and
Claude, with on-device memory extraction. Design reference: Pi's coding-agent layer.

Environment: macOS 27.0, base M4 24 GB, Xcode 27.0 + Metal Toolchain component. Tools use
`DynamicGenerationSchema` rather than `@Generable` so they can be defined at runtime.

## Spike 2, loop control: PASS (2026-09-22)

`Sources/spike-transcript`. On-device model called the `bash` tool (2.0 s). The transcript
was rebuilt with the tool output replaced by a pruned marker and a memory fact injected as
a prompt/response pair. `LanguageModelSession(tools:transcript:)` resumed from it and
answered from both the pruned turn and the injected fact (0.7 s).
Conclusion: compaction and memory injection are feasible via transcript rewriting.

## Spike 1, Claude adapter cost: PASS (2026-09-22)

`Sources/spike-claude`, ClaudeForFoundationModels 0.2.1, `.apiKey` auth, Sonnet 5.
Three turns with a ~1k-token instruction block and one tool call each:

| turn | input | cached input | output |
|---|---|---|---|
| 1 | 2422 | 1982 | 90 |
| 2 | 2688 | 2521 | 40 |
| 3 | 2737 | 2686 | 3 |

Conclusion: the adapter uses prompt caching and reports it through
`response.usage.input.cachedTokenCount`. The framework can own the Claude tier.

## Spike 3, open local model via MLX: PASS with caveats (2026-09-22)

`Sources/spike-mlx`, mlx-swift-lm `main` (MLXFoundationModels bridge), Qwen3-8B-4bit loaded
from `~/.cache/mlex/models/mlx-community/Qwen3-8B-4bit` via `ModelConfiguration(directory:)`.
Task: in a scratch repo, rebase `feature` onto `main` and commit an untracked file, with only
the `bash` tool. Ground truth checked with `git log` afterwards.

| config | result | wall time |
|---|---|---|
| reasoning off, terse instructions | FAIL: chained `git pull origin` + `rebase -i`, gave up | 12 s |
| reasoning on, one-command-per-call instructions | PASS (3 runs: 2 correct, 1 gave up after a commit error) | 300 to 580 s |
| reasoning off, one-command-per-call instructions | FAIL: switched to main, tried `git pull origin`, stopped | 15 s |

Micro-benchmarks (release build, model already loaded):

| operation | reasoning on | reasoning off |
|---|---|---|
| 200-token plain generation | 13.5 s | 13.6 s (about 13 tok/s) |
| forced single tool call (`echo hi`) | 30 s | 8 s |
| schema-constrained JSON (router-style) | 8 s | 5 s |
| model load from disk | 2 s | 2 s |

Conclusions:
- The bridge works end to end: tool calling, transcript, usage, and schema output all behave
  like the system model. Plumbing is not the problem.
- On a base M4, an 8B model is too slow for multi-step "routine commands" when it reasons and
  too unreliable when it doesn't. That tier is better served by Private Cloud Compute or Haiku.
- The 8B model is a good fit for bounded, single-shot work: routing decisions, fact extraction,
  and summaries at 5 to 8 s per call, offline. Constrain schema fields with enums; a free
  string field produced "Tier 1" instead of one of the listed values.
- Debug builds are not the cause of slowness; release changed nothing.

## Gotchas

- Swift 6 top-level code runs on the main actor; `DispatchSemaphore` + `Task {}` deadlocks.
  Spikes use async `@main` entry points.
- `MLXFoundationModels` is only on mlx-swift-lm `main`; the consumer must add
  `swift-huggingface` and `swift-transformers` and import `HuggingFace` and `Tokenizers` for the
  `#huggingFaceTokenizerLoader()` macro to expand.
- mlx-swift needs the Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` after
  `sudo xcodebuild -runFirstLaunch`.
- Anthropic API key lives in the macOS Keychain under service `mlex-anthropic`:
  `ANTHROPIC_API_KEY=$(security find-generic-password -s mlex-anthropic -w)`.

## Headless core + CLI (2026-09-22)

`MlexCore` and the `mlex` CLI exist and were exercised against a scratch project:

| backend | task | outcome |
|---|---|---|
| system (3B) | count CSV rows + mtime with tools | used read_file and bash, but miscounted (4 vs 3) and misread the file size as a date; also wrote an unasked-for .gitignore in chat. Fine for chat, weak with tools. |
| mlx Qwen3-8B-4bit | largest qty in CSV | correct, one tool call |
| claude:sonnet5 | append a CSV row via edit_file | correct; 93% of input cached |
| pcc | anything | fails with ModelManagerError 1046 |

Save + resume of a transcript across two CLI processes works (`/save`, `--resume`).

Private Cloud Compute needs the managed entitlement `com.apple.developer.private-cloud-compute`
on a signed app, granted by Apple on request. A Swift Package executable cannot carry it, and
the framework reports PCC as available anyway before the request fails. The CLI now reads its
own entitlements and reports the tier as unavailable. The shipped `fm` CLI (27.0) also only
accepts `--model system`. Consequence: the PCC tier only becomes real once mlex is a signed
app with that entitlement, so the SwiftUI app is where it gets tested.
