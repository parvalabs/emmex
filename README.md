# emmex

Local-first agent for the Mac, built directly on Apple's Foundation Models framework.
One session API across the built-in on-device model, Private Cloud Compute, MLX models
pulled from Hugging Face, and Claude. No Ollama, no LM Studio, no server process: models
run inside the app.

Status: exploration. A headless core, a CLI, and a first SwiftUI app exist.
See `docs/FEASIBILITY.md` for the spike results that shaped the design.

## Requirements

- macOS 27, Apple silicon, Apple Intelligence enabled
- Xcode 27 with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`)
- For Claude: an API key in the Keychain (`security add-generic-password -s emmex-anthropic -a "$USER" -w`)
  or `ANTHROPIC_API_KEY` in the environment

## What it does

- **Sessions** are saved per workspace and resumable; titles come from the first prompt.
- **Worktrees**: start a session on a git worktree (created outside the repo) so the main
  checkout stays untouched.
- **MCP servers** from `~/.emmex/mcp.json` or `<workspace>/.emmex/mcp.json` (`mcpServers`
  format, stdio or HTTP) become tools with grammar-constrained arguments.
- **Skills** (Agent Skills `SKILL.md`) from `.emmex/skills`, `.agents/skills`, `.claude/skills`
  in the workspace or home, listed to the model and forceable with `/skill:name`.
- **Prompt templates** in `.emmex/prompts` or `.claude/commands`, with `$1…$9` and `$ARGUMENTS`.
- **Context files** `AGENTS.md`, `CLAUDE.md`, `.emmex/SYSTEM.md`, `.emmex/APPEND_SYSTEM.md`.
- **Compaction**: older turns are folded into an on-device summary automatically when the
  context nears the window, or on demand.
- **Auto model**: `-m auto` routes each message to a tier (local, cheap, frontier) chosen by an
  on-device classifier, or by TypeSafe Jev with `"router": "jev"` in `~/.emmex/settings.json`
  and a key in Keychain service `emmex-jev`. Tiers map to specs in `settings.json` `routes`
  (default `system`, `claude:haiku`, `claude:sonnet5`) with fallback when a backend is missing.
  A deterministic floor raises the tier for judgment work (races, debugging, design, security,
  tradeoffs), multi-step edits, and questions about code, since a small classifier under-routes
  those. `emmex route -- "<prompt>"` shows the decision without running anything.
- **Routing log**: every turn records which tier and model answered, the router's confidence
  and reason, tool calls, errors, tokens, duration, and whether your next message looked like
  a correction. `emmex sessions routes <id>` prints it; badges under each message show it in the
  app; `emmex sessions review <id> [--model claude:opus5_5]` asks a strong model to judge each
  turn as appropriate, over-routed, or under-routed and stores the verdicts.
- **Memory**: after each turn the on-device model extracts durable facts (preferences, decisions,
  project facts, references), scoped to the project or to you (user-level facts apply in every
  workspace). Retrieval uses Apple's on-device sentence embeddings plus keyword overlap, so a
  differently worded question still finds the fact; duplicates are caught by wording and by
  embedding similarity. Lifecycle: facts are ranked by use count decayed over time (30-day
  half-life); a fact never used within 30 days or unused for 90 days is archived, not deleted;
  a new fact on the same subject with a different value supersedes the old one; and
  consolidation merges overlapping facts with the on-device model, keeping the newest verbatim
  when they conflict. Stored as JSON under Application Support/emmex/memory (one file per
  workspace plus global.json). `emmex memory list [--archived]|search|consolidate|forget|restore|clear`,
  `/memory` in chat, Memory in the Tools dialog. Disable with `"memory": false` in settings.
- **Fork and export**: `sessions fork <id> [--before N]`, `/fork N`, "Fork before this message"
  in the app; `sessions export <id> [file.html|.json]`, `/export`, File > Export Session.
- **Modes and permissions**: Chat (no tools) or Code. In Code, a permission level gates every
  write and command: `ask` (everything asks), `smart` (default: rules decide reads, workspace
  edits, protected paths, and dangerous patterns; scripts the harness wrote or in a trusted
  workspace run; the on-device model judges the rest and can only allow, never override a rule),
  or `full`. Approvals appear inline with Deny / Always allow / Allow; "always" saves a per-
  workspace prefix rule in `.emmex/permissions.json`. `emmex policy -- "<command>"` shows the
  decision without running it; `emmex trust` marks a workspace's own scripts as runnable.
- **Sandbox**: every shell command and every stdio MCP server runs under a default-deny Seatbelt
  profile (`sandbox-exec`, modeled on Codex's base policy): reads everywhere except `~/.ssh`,
  `~/.aws`, `~/.gnupg`, Keychains, `gh`/`kube`/`gcloud` configs, `.netrc`, and shell history;
  writes only inside the workspace, a per-session temp directory, the per-user temp and cache
  directories, and package-manager caches; `.git/hooks`, `.git/config`, `.gitconfig`, shell rc
  files, `.mcp.json`, `.emmex`, `.claude`, `.cursor`, `.vscode`, `.idea` never writable, and
  their ancestors cannot be renamed. Network goes only through a local filtering proxy on
  localhost: commands that need it (git, npm, pip, cargo, brew, curl, gh…) get a domain
  allowlist (package registries, GitHub, Hugging Face, plus `network.allowedDomains` in
  settings and `allowedDomains` in `.emmex/permissions.json`); `full` allows every domain;
  addresses that resolve to loopback, private ranges, or cloud metadata are always refused,
  and proxy denials are reported in the tool result. A command the sandbox denies can be rerun
  unsandboxed after approval (`"unsandboxedRetry": false` disables). MCP servers take
  `"network": "none" | "all" | ["domain", …]` and `"sandbox": false` per server. SwiftPM
  commands get `--disable-sandbox` because macOS refuses nested sandboxes. `emmex sandbox --
  "<cmd>"` runs a command under the profile for testing. Disable with `"sandbox": false`.
- **Effort** per message: `off | low | medium | high` (Claude effort, MLX thinking on/off).
- **Explicit model loading**: MLX models load only from the Models view; several can stay loaded, with headroom warnings.

## CLI

```bash
swift build -c release
.build/release/emmex models list                       # every backend and whether it is ready
.build/release/emmex models pull mlx-community/Qwen3-8B-4bit
.build/release/emmex run -m system "How many rows does items.csv have?"
.build/release/emmex chat -m mlx:mlx-community/Qwen3-8B-4bit --workspace ~/code/app
.build/release/emmex chat --worktree feature-x         # session on a fresh worktree
.build/release/emmex chat --resume 80123aae            # resume by id prefix
.build/release/emmex sessions list                     # sessions for the current workspace
.build/release/emmex worktrees list|add|remove
.build/release/emmex mcp                               # configured MCP servers and their tools
.build/release/emmex chat -m auto                      # route each message to the cheapest capable tier
.build/release/emmex memory list                       # what emmex remembers about this workspace
```

In chat: `/model <spec>`, `/effort <level>`, `/title <text>`, `/compact`, `/context`, `/route`,
`/memory`, `/fork [N]`, `/export [file]`, `/skills`, `/prompts`, `/tools`, `/sessions`,
`/skill:<name> [args]`, `/<template> [args]`.

Model specs: `auto`, `system`, `pcc`, `claude:<name or API id>`, `mlx:<org/name>`,
and `<provider>:<model>` for any OpenAI-compatible chat-completions endpoint.

Claude: the picker shows `claude:opus5_5`, `claude:sonnet5_5` and `claude:haiku`. Other short names
known to emmex (`fable5_1`, `fable5`, `opus5`, `sonnet5`, `opus4_8`, `opus4_7`, `opus4_6`, `sonnet4_6`) and any
Anthropic API id (`claude:claude-opus-4-7`) work as specs everywhere; list them under
`"claudeModels"` in `~/.emmex/settings.json` to add them to the picker.

Other providers: Built-in providers:
`openai` (key in Keychain `emmex-openai` or `OPENAI_API_KEY`), `bedrock` (Bedrock API key in
`emmex-bedrock` or `AWS_BEARER_TOKEN_BEDROCK`; us-east-1 by default; only models that support
Bedrock's Chat Completions API, e.g. `openai.gpt-oss-120b-1:0`, not Claude or Nova), and
`ollama` (local, no key). Add or override providers in `~/.emmex/settings.json`:

```json
{ "providers": { "groq": { "url": "https://api.groq.com/openai/v1", "keychain": "emmex-groq",
                            "models": ["llama-3.3-70b-versatile"], "guided": false, "context": 128000 } } }
```

Fields: `url`, `keychain` or `env` for the key, optional `headers`, `models` for the picker,
`guided` (structured output support, default true), `context`, `requiresKey` (false for local servers).

Gemini, through Google's OpenAI-compatible endpoint (store the key with
`security add-generic-password -s emmex-gemini -a "$USER" -w`):

```json
{ "providers": { "gemini": { "url": "https://generativelanguage.googleapis.com/v1beta/openai",
                              "keychain": "emmex-gemini", "env": "GEMINI_API_KEY",
                              "models": ["gemini-3.8-flash"] } } }
```
MLX weights live in `~/.cache/emmex/models/<org>/<name>`. Set `EMMEX_USAGE=1` to print token usage.

## Memory

Pulling a model only writes to disk. In the app, weights load only when you click Load model
in the Models view, and stay loaded until you unload them there or from the sidebar. Several MLX
models can be loaded at once; when a new one does not fit, the least recently used is unloaded
first. Until a model is loaded, the model picker shows it disabled, a session that uses it opens
without starting, and auto routing skips it. Before loading, emmex compares the model's size with
available memory and warns when it won't fit. The CLI loads a model when you name it, since that is
already an explicit request. In `chat`, `/model <spec>` switches models and keeps the transcript.

## App and web UI

The UI is HTML, CSS, and JS served by the app itself on localhost and shown in a `WKWebView`.
The same UI runs in any browser for development:

```bash
./scripts/bundle-app.sh debug && open .build/Emmex.app      # the Mac app
.build/debug/emmex serve --open                             # same UI at http://127.0.0.1:8765
.build/debug/emmex serve --web-root Sources/EmmexServer/Resources/web   # edit assets live
```

Sidebar: workspace switcher with recents, new session (plain or on a worktree), sessions
grouped by day. Top bar: session title (double-click to rename), worktree badge, context ring
(click to compact). Composer: model and effort pickers, `/` suggestions for skills and templates,
follow-up queue, stop. Models and Tools dialogs manage MLX pulls, MCP servers, skills,
templates, and memory. Right-click a message to fork before it. The app adds native menus
(New Session, Open Folder, Compact, Export, Open in Browser) and Inspect Element for debugging.
Private Cloud Compute needs Apple's managed entitlement and a real signing identity; see
`scripts/Emmex.entitlements`.

## Layout

| path | what |
|---|---|
| `Sources/EmmexCore` | model specs and backends, MLX model store (pull, list, load), tools (bash, read, write, edit), agent session with streaming events and transcript persistence |
| `Sources/emmex` | the CLI |
| `Sources/EmmexServer` | localhost HTTP + SSE server, view-independent `AppController`, and the web UI in `Resources/web` |
| `Sources/EmmexApp` | the Mac shell: a `WKWebView` window over the server, plus native menus |
| `scripts/` | app bundling and entitlements |
| `Sources/spike-*` | the three feasibility spikes, kept runnable |

Tools are defined with `DynamicGenerationSchema` rather than `@Generable`, so they can be
declared at runtime and the package builds without the macro plugin.

## Earlier names

The project was called mlex until 2026-09-24 and emlex until 2026-09-27. The first run of
emmex moves `~/Library/Application Support/<old>`, `~/.cache/<old>` and `~/.<old>` to their
`emmex` names and leaves a symlink at each old path, so git worktrees and saved sessions keep
working through the chain. `EMLEX_*` and `MLEX_*` environment variables, `emlex-*` and
`mlex-*` Keychain items and per-project `.emlex/` and `.mlex/` folders are still read when the
`emmex` ones are missing.

## Vendored dependencies

`Vendor/mlx-swift-lm` is a copy of [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
(`main` at `ee673d6a`) with one patch: the FoundationModels adapter keeps the KV cache between
requests, so a long session only prefills its new tokens on each turn. The patch is documented in
`Vendor/mlx-swift-lm/EMMEX-PATCHES.md`; `EMMEX_MLX_PROMPT_CACHE=0` disables it.
