# mlex

Local-first agent for the Mac, built directly on Apple's Foundation Models framework.
One session API across the built-in on-device model, Private Cloud Compute, MLX models
pulled from Hugging Face, and Claude. No Ollama, no LM Studio, no server process: models
run inside the app.

Status: exploration. A headless core, a CLI, and a first SwiftUI app exist.
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

Reasoning effort is per message and off by default: `--effort off|low|medium|high` on `run` and
`chat` (or `/effort <level>` inside chat), and a picker in the app toolbar. On Claude it sets the
effort level; on MLX models such as Qwen3 it switches thinking on or off, which on a base M4 is
the difference between about 12 s and 50 s for a one-line answer.
MLX weights live in `~/.cache/mlex/models/<org>/<name>`. Set `MLEX_USAGE=1` to print token usage.

## Memory

Pulling a model only writes to disk. Weights load when a model is selected and stay resident
until you select another MLX model, which evicts the previous one, or click the memory chip
icon next to the loaded model. Only one MLX model is ever resident; the Apple on-device model is
managed by the system. Before loading, mlex compares the model's size with available memory and
warns when it won't fit. In `chat`, `/model <spec>` switches models and keeps the transcript.

## App

```bash
./scripts/bundle-app.sh debug      # builds MlexApp and wraps it into .build/Mlex.app (ad-hoc signed)
open .build/Mlex.app
```

Sidebar: workspace folder, every backend with a ready indicator, and a pull field for
Hugging Face MLX models with live progress. Detail: streaming chat with a tool timeline.
Switching models keeps the conversation: the new session starts from the old transcript.
Private Cloud Compute needs Apple's managed entitlement and a real signing identity; see
`scripts/Mlex.entitlements`.

## Layout

| path | what |
|---|---|
| `Sources/MlexCore` | model specs and backends, MLX model store (pull, list, load), tools (bash, read, write, edit), agent session with streaming events and transcript persistence |
| `Sources/mlex` | the CLI |
| `Sources/MlexApp` | SwiftUI app: model picker, chat, tool timeline |
| `scripts/` | app bundling and entitlements |
| `Sources/spike-*` | the three feasibility spikes, kept runnable |

Tools are defined with `DynamicGenerationSchema` rather than `@Generable`, so they can be
declared at runtime and the package builds without the macro plugin.
