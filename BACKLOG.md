# Backlog

Pending work, roughly by priority within each section. Move items to "Done" with the commit
that closed them rather than deleting them. Dates are when the item was added.

## Blocked on outside parties

- **Private Cloud Compute** (2026-09-23): waiting on Apple's approval of the managed
  capability (Small Business Program applied). Then: development certificate, App ID with the
  PCC capability, provisioning profile, and `MLEX_SIGN_IDENTITY`/`MLEX_PROFILE` in
  `scripts/bundle-app.sh`. Add quota state and the iCloud+ upgrade sheet to the model list.
- **Jev router validation** (2026-09-23): the request shape in `JevRouter` follows
  TypeSafe's published examples but has not run against a live key. Measure routing
  accuracy against the on-device router on real prompts once a key exists.
- **Name check** (2026-09-22): "mlex" collides with MLex (mlex.com) and MLExchange
  (github.com/mlexchange/mlex); one letter from Apple's MLX. Decide before anything public.

## Safety

- **Kernel violation log** (2026-09-23): Seatbelt denials could not be read from the unified
  log on macOS 27 (neither `log show` predicates nor `(trace)` produced entries); today the
  tool only detects "Operation not permitted" in output. Find the right subsystem or use a
  `(deny default (with message …))` variant if it logs.
- **Per-user temp is shared across sessions** (2026-09-23): swiftc and xcrun write to the
  per-user `DARWIN_USER_TEMP_DIR`/`CACHE_DIR` regardless of `$TMPDIR`, so those stay writable
  (mode 700, but shared between mlex sessions). `/tmp` itself is closed.
- **Proxy auth fallback** (2026-09-23): git sends no proxy credentials until challenged, so
  unauthenticated proxy requests use the most recently registered policy; with concurrent
  commands the attribution can be wrong. Issue a 407 challenge instead.

- **Shell AST parsing** (2026-09-23): text-based splitting misses `git -C .. push`-style
  evasions; OpenCode uses tree-sitter-bash. Consider a real parser or, cheaper, more opaque
  patterns that force asking.
- **MCP tool gating** (2026-09-23): only name heuristics (`write`, `delete`, `run`…). Use
  MCP tool annotations (readOnlyHint / destructiveHint) when servers provide them.

## Harness

- **Session tree / branching** (2026-09-23): pi's `/tree` (in-file branches with LLM
  summaries when leaving a branch). Fork exists; a tree view does not.
- **Steering mid-turn** (2026-09-23): messages typed during a turn are queued as
  follow-ups; true steering would inject into the running loop.
- **Tasks mode** (2026-09-23): the Cowork equivalent: autonomous multi-step runs over any
  folder, later scheduled. Needs the sandbox first.
- **Provider model discovery** (2026-09-23): list models from `GET /v1/models` for OpenAI,
  LiteLLM, and Ollama instead of the configured list; fall back for Bedrock.
- **Bedrock Converse adapter** (2026-09-23): Bedrock's OpenAI-compatible endpoint does not
  serve Claude or Nova; a Converse-based `LanguageModel` would, or route through LiteLLM.
- **Memory retrieval quality** (2026-09-23): Apple's sentence embedding separates short
  facts only by ~0.15 cosine; if merges misfire in practice, try an MLX embedding model.
- **Compaction summaries** (2026-09-22): the 3B model's summaries are shallow; consider
  the frontier model for the fold when the session is already on one.

## App

- **Loading state for MLX models** (2026-09-22): the picker shows a spinner; the
  timeline should say what is loading and how big it is.
- **Silent exit on launch** (2026-09-22): seen twice in the SwiftUI era, never reproduced;
  direct exec of the bundle binary opens no window while `open` does. Not understood.
- **Keyboard shortcuts** (2026-09-23): ⌘N, ⌘K compact, ⌘. stop exist; add session
  switching and a command palette.

## Done

- Router escalation floor after a dogfood session sent a concurrency fix to Haiku (Opus review:
  under-routed): judgment cues raise to frontier, multi-step edits and code questions to cheap;
  `mlex route -- "<prompt>"` shows decisions (`50ff930`).
- In-page dialogs for session rename and worktree branch, implemented by mlex itself on Auto
  (routed to Haiku, 15 tool calls, 25 s, no approvals needed; Opus review: appropriate) (`fe9a16d`).
- Routing log per turn with outcome signals, `sessions routes`, Opus reviewer, badges in the app (`3d160da`).

- Feasibility spikes: transcript rewrite, Claude prompt caching, MLX bridge (`docs/FEASIBILITY.md`).
- Core, CLI, sessions, worktrees, MCP, skills, templates, context files, compaction (`64b7a9c`…`42616e4`).
- Web UI served by the app; WKWebView shell (`5810bfb`, `1b7b883`).
- Router with `auto` model; memory with embeddings, scopes, decay, expiry, supersede,
  consolidation, auto-consolidation (`c719ddc`, `d1b9ccd`, `c7d55f2`, `83889a5`).
- OpenAI-compatible providers (`0acbcf0`). Permissions and modes (`9edc633`).
- Seatbelt sandbox for shell commands with per-command network grants (`fc8aff1`).
