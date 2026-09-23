# mlex

Local-first agent for the Mac, built directly on Apple's Foundation Models framework.
One session API across the built-in on-device model, Private Cloud Compute, MLX models
pulled from Hugging Face, and Claude. No Ollama, no LM Studio, no server process: models
run inside the app.

Status: exploration. A headless core and CLI exist; the SwiftUI app is next.
See `docs/FEASIBILITY.md` for the spike results that shaped the design.

## Requirements

- macOS 27, Apple silicon, Apple Intelligence enabled
- Xcode 27 with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`)
- For Claude: an API key in the Keychain (`security add-generic-password -s mlex-anthropic -a "$USER" -w`)
  or `ANTHROPIC_API_KEY` in the environment

## CLI

```bash
swift build -c release
.build/release/mlex models list                       # every backend and whether it is ready
.build/release/mlex models pull mlx-community/Qwen3-8B-4bit
.build/release/mlex run -m system "How many rows does items.csv have?"
.build/release/mlex run -m mlx:mlx-community/Qwen3-8B-4bit "…"
.build/release/mlex run -m pcc "…"
.build/release/mlex run -m claude:sonnet5 "…"
.build/release/mlex chat -m system                    # /save <file> and --resume <file>
```

Model specs: `system`, `pcc`, `claude:<sonnet5|opus5_5|opus4_8|id>`, `mlx:<org/name>`.
MLX weights live in `~/.cache/mlex/models/<org>/<name>`. Set `MLEX_USAGE=1` to print token usage.

## Layout

| path | what |
|---|---|
| `Sources/MlexCore` | model specs and backends, MLX model store (pull, list, load), tools (bash, read, write, edit), agent session with streaming events and transcript persistence |
| `Sources/mlex` | the CLI |
| `Sources/spike-*` | the three feasibility spikes, kept runnable |

Tools are defined with `DynamicGenerationSchema` rather than `@Generable`, so they can be
declared at runtime and the package builds without the macro plugin.
