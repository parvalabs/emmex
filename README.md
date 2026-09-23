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

## What it does

- **Sessions** are saved per workspace and resumable; titles come from the first prompt.
- **Worktrees**: start a session on a git worktree (created outside the repo) so the main
  checkout stays untouched.
- **MCP servers** from `~/.mlex/mcp.json` or `<workspace>/.mlex/mcp.json` (`mcpServers`
  format, stdio or HTTP) become tools with grammar-constrained arguments.
- **Skills** (Agent Skills `SKILL.md`) from `.mlex/skills`, `.agents/skills`, `.claude/skills`
  in the workspace or home, listed to the model and forceable with `/skill:name`.
- **Prompt templates** in `.mlex/prompts` or `.claude/commands`, with `$1…$9` and `$ARGUMENTS`.
- **Context files** `AGENTS.md`, `CLAUDE.md`, `.mlex/SYSTEM.md`, `.mlex/APPEND_SYSTEM.md`.
- **Compaction**: older turns are folded into an on-device summary automatically when the
  context nears the window, or on demand.
- **Auto model**: `-m auto` routes each message to a tier (local, cheap, frontier) chosen by an
  on-device classifier, or by TypeSafe Jev with `"router": "jev"` in `~/.mlex/settings.json`
  and a key in Keychain service `mlex-jev`. Tiers map to specs in `settings.json` `routes`
  (default `system`, `claude:haiku`, `claude:sonnet5`) with fallback when a backend is missing.
- **Memory**: after each turn the on-device model extracts durable facts (preferences, decisions,
  project facts, references), scoped to the project or to you (user-level facts apply in every
  workspace). Retrieval uses Apple's on-device sentence embeddings plus keyword overlap, so a
  differently worded question still finds the fact; duplicates are caught by wording and by
  embedding similarity; use counts drive pruning. Stored as JSON under Application Support/mlex/
  memory (one file per workspace plus global.json). `mlex memory list|search|forget|clear`,
  `/memory` in chat, Memory in the Tools dialog. Disable with `"memory": false` in settings.
- **Fork and export**: `sessions fork <id> [--before N]`, `/fork N`, "Fork before this message"
  in the app; `sessions export <id> [file.html|.json]`, `/export`, File > Export Session.
- **Effort** per message: `off | low | medium | high` (Claude effort, MLX thinking on/off).
- **Memory-aware model loading**: one MLX model resident at a time, with headroom warnings.

## CLI

```bash
swift build -c release
.build/release/mlex models list                       # every backend and whether it is ready
.build/release/mlex models pull mlx-community/Qwen3-8B-4bit
.build/release/mlex run -m system "How many rows does items.csv have?"
.build/release/mlex chat -m mlx:mlx-community/Qwen3-8B-4bit --workspace ~/code/app
.build/release/mlex chat --worktree feature-x         # session on a fresh worktree
.build/release/mlex chat --resume 80123aae            # resume by id prefix
.build/release/mlex sessions list                     # sessions for the current workspace
.build/release/mlex worktrees list|add|remove
.build/release/mlex mcp                               # configured MCP servers and their tools
.build/release/mlex chat -m auto                      # route each message to the cheapest capable tier
.build/release/mlex memory list                       # what mlex remembers about this workspace
```

In chat: `/model <spec>`, `/effort <level>`, `/title <text>`, `/compact`, `/context`, `/route`,
`/memory`, `/fork [N]`, `/export [file]`, `/skills`, `/prompts`, `/tools`, `/sessions`,
`/skill:<name> [args]`, `/<template> [args]`.

Model specs: `auto`, `system`, `pcc`, `claude:<sonnet5|haiku|opus5_5|opus4_8|id>`, `mlx:<org/name>`.
MLX weights live in `~/.cache/mlex/models/<org>/<name>`. Set `MLEX_USAGE=1` to print token usage.

## Memory

Pulling a model only writes to disk. Weights load when a model is selected and stay resident
until you select another MLX model, which evicts the previous one, or click the memory chip
icon next to the loaded model. Only one MLX model is ever resident; the Apple on-device model is
managed by the system. Before loading, mlex compares the model's size with available memory and
warns when it won't fit. In `chat`, `/model <spec>` switches models and keeps the transcript.

## App and web UI

The UI is HTML, CSS, and JS served by the app itself on localhost and shown in a `WKWebView`.
The same UI runs in any browser for development:

```bash
./scripts/bundle-app.sh debug && open .build/Mlex.app      # the Mac app
.build/debug/mlex serve --open                             # same UI at http://127.0.0.1:8765
.build/debug/mlex serve --web-root Sources/MlexServer/Resources/web   # edit assets live
```

Sidebar: workspace switcher with recents, new session (plain or on a worktree), sessions
grouped by day. Top bar: session title (double-click to rename), worktree badge, context ring
(click to compact). Composer: model and effort pickers, `/` suggestions for skills and templates,
follow-up queue, stop. Models and Tools dialogs manage MLX pulls, MCP servers, skills,
templates, and memory. Right-click a message to fork before it. The app adds native menus
(New Session, Open Folder, Compact, Export, Open in Browser) and Inspect Element for debugging.
Private Cloud Compute needs Apple's managed entitlement and a real signing identity; see
`scripts/Mlex.entitlements`.

## Layout

| path | what |
|---|---|
| `Sources/MlexCore` | model specs and backends, MLX model store (pull, list, load), tools (bash, read, write, edit), agent session with streaming events and transcript persistence |
| `Sources/mlex` | the CLI |
| `Sources/MlexServer` | localhost HTTP + SSE server, view-independent `AppController`, and the web UI in `Resources/web` |
| `Sources/MlexApp` | the Mac shell: a `WKWebView` window over the server, plus native menus |
| `scripts/` | app bundling and entitlements |
| `Sources/spike-*` | the three feasibility spikes, kept runnable |

Tools are defined with `DynamicGenerationSchema` rather than `@Generable`, so they can be
declared at runtime and the package builds without the macro plugin.
