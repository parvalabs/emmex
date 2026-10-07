# Decisions

Why emmex is built the way it is: every substantive discussion that shaped the project, what
was considered, what was decided and by whom, and what is still open. Pending work itself lives
in [BACKLOG.md](../BACKLOG.md); measured results live in [FEASIBILITY.md](FEASIBILITY.md) and
[evals/RESULTS.md](../evals/RESULTS.md).

Dates are commit dates (Pacific time). Add an entry in the same commit as any new decision.
Research findings are recorded as they stood at the time; check them before relying on them.

## Standing decisions

These hold today; the log below explains each.

- **The framework is the loop.** emmex is a Swift harness on Apple's FoundationModels
  (macOS 27): `LanguageModelSession` runs the loop, the `LanguageModel` protocol swaps backends
  (on-device model, Private Cloud Compute, Claude, MLX, OpenAI-compatible providers). Pi's
  coding agent is the design reference, not a fork.
- **Route each message to the cheapest capable tier.** Local, cheap and frontier tiers, decided by
  the on-device model plus deterministic floor rules; every decision is logged and reviewable.
- **Background work stays on-device.** Memory extraction, consolidation, routing, safety judging
  and summaries run on the Apple model; after Claude turns, the cheap Claude tier extracts facts.
- **Web UI in a native shell.** HTML/CSS/JS served by the app and shown in a `WKWebView`, so the
  same UI runs in a browser for development and can be driven by Claude.
- **Rules first, the model only loosens.** In smart mode, deterministic rules decide what they
  can; the on-device judge may allow a gray-zone command but never overrule a rule.
- **Everything runs sandboxed.** Default-deny Seatbelt for shell commands and MCP servers, with a
  filtering network proxy and credential reads denied.
- **Secrets never leave.** Messages with passwords, tokens or keys are refused before any model,
  memory or session file sees them.
- **Models load only on purpose.** The app loads an MLX model only from the Models view.
- **Keys in the Keychain.** Never in files; never printed.
- **Process:** Conventional Commits split by concern; pending work in BACKLOG.md, dated, moved
  to Done with its commit; eval numbers in evals/RESULTS.md updated with the change that moves them.

## Log

### 2026-09-22 · Is FoundationModels macOS 27 only?

**Asked:** can a harness use the Foundation Models framework on macOS 26, or only 27?
**Found (on the machine, then macOS 26.0.1, M4, 24 GB):** the `fm` CLI is 27 only. The Swift
framework (sessions, tools, guided generation, streaming) shipped at WWDC25 and works on 26, and
Apple's Python SDK supports 26. Private Cloud Compute, image input, the `LanguageModel`
protocol, Dynamic Profiles and the token usage API are 27 only. The `@Generable` macros need full
Xcode; the macro-free `DynamicGenerationSchema` path works with the Command Line Tools and suits
tools defined at runtime. The on-device model is about 3B parameters with a 4096-token window on
26 (8192 on 27).
**Decided:** build on the Swift framework, not by shelling out to `fm`, which would lose the tool loop.

### 2026-09-22 · The routing idea, on-device memory, and moving to macOS 27

**Proposed (user):** feed the last 3000 tokens to the Apple model on every prompt, answer locally
when it is confident, otherwise call Claude or a local model; use the local model to extract
facts for memory.
**Assessment:** this is a model cascade (FrugalGPT, RouteLLM) and lives or dies on confidence.
The framework exposes no logprobs, the 4096-token window leaves little room after 3000 tokens,
and in agent sessions the answer is rarely in the recent tail. Reshaped: the local model routes
and verifies, classifying each turn into an enum, and answers only where a wrong answer is cheap.
Memory extraction is the strongest part: short-context, typed-output work that suits an
on-device model (mem0, Letta and Zep do it in the cloud). Nothing combined Apple's model as the
cheap tier in front of Claude.
**Decided (user):** upgrade to macOS 27, for the `LanguageModel` protocol, Private Cloud Compute
(32K context, reasoning), the token usage API and the newer on-device model.

### 2026-09-22 · Which tasks to route, and Jev

**Asked:** the target is routine commands ("rebase and commit the changes") and easy questions
("when was this file updated?"), which waste an expensive model; what is "Jeb", a fast cheap
classifier, and how is it integrated elsewhere?
**Found:** the model is Jev from TypeSafe AI (released 2026-09-15). It never generates text; it
returns a choice, score or yes/no with a calibrated probability, which is the missing confidence
signal. At the time: 70-500 ms, $0.042 per million input tokens, 64K context, API only, one
week old with self-reported benchmarks. Integrations existed for Claude Code (a routing proxy,
compaction and pruning hooks, a prompt-injection guard, an MCP server, a plugin) and gateways,
but none paired Jev with Apple's on-device model.
**Decided:** three tiers (on-device, cheap cloud such as Haiku 4.5, frontier). Routine commands
go to the cheap tier, since a 3B model with a small window fumbles them. Router input is the
prompt plus a compact state summary, not a raw tail.
**Status:** `JevRouter` exists with an unverified request shape; Jev was never validated (no key).

### 2026-09-22 · New harness, plugin, or fork?

**Asked:** build a new harness, or a plugin/hook/skill for existing ones? Then: fork OpenCode or
Pi and port it to Swift?
**Options:** a local Messages-API proxy plus hooks in front of Claude Code (cheapest; the logic
lives at the model boundary). A TypeScript fork of Pi or OpenCode with a Swift sidecar (keeps
upstream, but the `LanguageModel` protocol stays outside). A Swift harness with Pi as the
blueprint (native, no upstream). OpenCode and Pi are both MIT, so forking and porting are fine
with the notice kept; a TypeScript-to-Swift port is a rewrite either way.
**Decided (user):** a Swift harness modeled on Pi. Pi's layers map onto the framework: pi-ai and
pi-agent-core become the `LanguageModel` protocol, `LanguageModelSession` and `Tool`;
Anthropic's ClaudeForFoundationModels (Apache-2.0) supplies Claude; Apple's
foundation-models-utilities supplies an OpenAI-compatible adapter. Left to write: the coding
agent layer and a UI.
**Why Swift:** one loop for every backend; grammar-constrained output on local models at decode
time; in-process models with no server; the on-device model and PCC are reachable only from
Swift. **Costs:** macOS 27 only, API churn, and the Claude adapter's caching and thinking had to
be proven.

### 2026-09-22 · Feasibility spikes

**Decided:** before building, prove three risks. Results in [FEASIBILITY.md](FEASIBILITY.md):
- **Loop control: pass.** An edited transcript (pruned tool output, an injected fact) resumes.
- **Claude cost: pass.** Prompt caching works through the adapter: 82% of input cached on turn 1,
  98% by turn 3.
- **MLX: pass with caveats.** Qwen3-8B loads in 2 s and calls tools, but rebase-and-commit was
  right only with reasoning on (300-580 s, 2 of 3 runs) and always wrong with it off. About
  13 tok/s generation. Free string fields drift ("Tier 1"), so constrain fields with enums.
**Outcome:** local models do routing, memory and summaries; the cheap cloud tier does routine
commands; Claude does the rest. Setup notes: the API key went into the Keychain (the first one
was not an API key); Xcode 27 plus its Metal Toolchain are required; the MLX bridge exists only
on mlx-swift-lm `main`.

### 2026-09-22 · UI-first

**Decided (user):** make the product UI-first, like pi-gui: pull MLX models and
use them at once, with no Ollama or LM Studio, next to the built-in model; keep a headless CLI
for development and tests.
**Assessment:** "MLX without Ollama" alone is a crowded field (nativ, macMLX, ChatMLX, Klee). The
real differentiators are one session API across the Apple model, PCC, MLX and Claude with
mid-session switching, and an agent-first rather than chat-first design.
**Process:** Conventional Commits, requested by the user and used from the first commit.

### 2026-09-22 · Reasoning off by default, effort per message

**Found:** every MLX session had reasoning on, with hidden thinking tokens: 52 s instead of 12 s
for a trivial answer, and the thinking made it worse.
**Decided:** reasoning off by default; effort off, low, medium or high per message across
backends (Claude effort; MLX thinking on or off only; Apple reasoning levels). Commit `1b24daf`.

### 2026-09-22 · Model memory: what loads when

**Asked:** when does an MLX model load, and what happens with ten pulled models?
**Found:** pulling only writes to disk; the first message loaded the weights, and nothing ever
evicted them, so every used model stayed resident.
**Decided (user):** keep one model resident, show it, allow unloading, warn about memory
headroom. Commit `403e23b`. Later replaced by several residents and explicit loading (2026-09-24
and 2026-09-27).

### 2026-09-22 · Private Cloud Compute: what it takes

**Found:** PCC needs Apple's managed entitlement `com.apple.developer.private-cloud-compute` on a
signed app with its own App ID; a SwiftPM binary can't carry it, and without it requests fail
with error 1046 even though PCC reports available. Small apps get it at no cloud cost through
the Small Business Program. The quota belongs to the Mac's signed-in Apple Account and rises
with iCloud+; there is nothing to enable on the developer side, the app never learns the account
(a system daemon issues anonymous tokens), and when nobody is signed in PCC reports unavailable.
**Decided:** signing support in the bundle script (`de7f25f`); quota and availability messages
in the model list once the entitlement exists.
**Status:** blocked on Apple; the user applied through the Small Business Program.

### 2026-09-22 · Silent exit on launch

**Decided (user):** "debug that later if it happens again". It never reproduced. Related quirk:
the app opens no window when its binary runs directly, so tests launch copies with `open -n`.

### 2026-09-22 → 2026-09-23 · Pi parity, then a Cursor-like design

**Asked (user):** everything Pi offers, especially MCP servers, skills, workspaces, worktree
sessions and resume, in a clean, modern design like Cursor.
**Found:** Pi has no native MCP, no worktrees and no per-tool approval or sandbox, only project
trust. Its skills use the Agent Skills format; its sessions are JSONL trees.
**Built:** sessions per workspace, worktree sessions, MCP over stdio and HTTP, skills, prompt
templates, context files, compaction with on-device summaries (`64b7a9c`…`42616e4`); fork,
export, follow-up queue and stop (`7d56aa7`); the auto model with tier routing (`c719ddc`); memory
(`08a9fd6`). Compaction must cut at user-turn boundaries, since Apple's tokenizer rejects a tool
output whose call was summarized away (`d05661b`).
**Status:** session tree and mid-turn steering are on the backlog.

### 2026-09-23 · Web UI instead of SwiftUI

**Problem:** screen recording was never granted (the user's decision), so the assistant rendered
the app offscreen to check it. The user worried the screenshot was being altered; it was the
app's own render of a test build, with placeholders where AppKit controls can't be drawn.
**Options:** the app photographs its own window plus a debug server (under an hour); a web UI in
a `WKWebView`, the way Claude Desktop is built (a rewrite of the UI layer, less native, but
debuggable and drivable in a browser); a second web front-end (two UIs, rejected); granting the
permission once.
**Decided (user):** the web UI. "I want you to interact with the UI, not only watch it", and
looking great matters more than feeling native. Built as a dependency-free localhost HTTP + SSE
server, a view-independent controller and a WebKit shell; `emmex serve` runs it in any browser.
Commit `5810bfb`.

### 2026-09-23 · Memory: design, lifecycle, consolidation

**Bug:** the app said it had six memories while the agent denied having any: a resumed session
kept its old instructions. Fixed by recomposing instructions on every resume (`0304d42`).
**How it works:** after every turn the on-device model extracts up to four typed facts
(preferences, decisions, project facts, references), skipping transient detail. Facts are
deduplicated by wording and embeddings and stored as JSON per workspace plus a global file for
facts about the user. Retrieval uses Apple's sentence embeddings (512 dimensions, about 2.5 ms)
plus keyword overlap (`d1b9ccd`).
**Asked (user):** is there an LRU for old facts? Should consolidation prefer the most recent?
Does consolidation run on a schedule?
**Decided:**
- Use counts decay with a 30-day half-life; facts never used within 30 days or idle for 90 are
  archived, not deleted; a new fact on the same subject supersedes the old one (`c7d55f2`).
- The newest statement wins on content and use counts carry importance. The 3B model could not
  merge conflicting facts reliably (it concatenated them), so it only classifies a cluster as
  duplicate, conflict, complementary or different; duplicates and conflicts keep the newest fact
  verbatim, and only complementary facts are merged.
- Consolidation is triggered by activity, not a clock, since the app may be closed: after 8 new
  facts, or a day with at least 10 active facts. Sibling facts ("the test command is make test"
  vs "the lint command is make lint") scored like true updates, so supersede goes through the
  classifier and facts from the same turn are never compared (`83889a5`).

### 2026-09-23 · Other providers

**Asked:** GPT, Bedrock, then LiteLLM.
**Decided:** one adapter for any OpenAI-compatible endpoint (Apple's `ChatCompletionsLanguageModel`),
with OpenAI, Bedrock and Ollama built in and anything else in settings; keys in the Keychain or
an environment variable (`0acbcf0`). LiteLLM is just another provider entry.
**Found:** Bedrock's OpenAI-compatible endpoint does not serve Claude or Nova (those need the
Converse API). **Status:** model discovery and a Converse adapter are on the backlog.

### 2026-09-23 · Modes and smart permissions

**Asked:** modes like Claude Code's (chat, code, cowork)? A "smart auto" that asks the built-in
model whether a command is safe and runs scripts only if the harness wrote them or they sit in a
trusted folder? Then: compare with OpenCode and Pi.
**Decided:** two axes. Capability: Chat (no tools) and Code (Tasks, the Cowork equivalent, is on
the backlog). Permission: Ask, Smart (default) and Full. Smart stacks rules (reads always run,
workspace edits allowed, hard denies ask), provenance (scripts written this session or in a
trusted workspace) and the on-device judge for the gray zone. The judge's output is a guided
enum, and it can only allow, never overrule a rule, because a 3B model can be fooled by
obfuscation. Commit `9edc633`.
**Borrowed:** from OpenCode and Claude Code, wrapper stripping, allow rules that must cover every
subcommand, protected paths, an arity table for "always allow" prefixes and a doom-loop check;
from Pi, workspace trust and failing closed when nobody can approve. Pi has no gating; OpenCode
defaults bash and edits to allow.

### 2026-09-23 · Backlog convention

**Asked (user):** record pending things in a file. **Decided:** BACKLOG.md, dated items grouped as
blocked, safety, harness and app, added in the same commit as the work that surfaced them and
moved to Done with their hash (`bcb1887`).

### 2026-09-23 · Sandbox, matched to the competitors

**Built first:** Seatbelt through `sandbox-exec`: writes only in the workspace, temp and package
caches; credential reads denied (`db488da`).
**Compared:** the same mechanism as Anthropic's sandbox runtime (Claude Code), Codex and Cursor;
OpenCode and Pi ship none. emmex was ahead on denying credential reads by default and on having a
policy layer in front, and behind on network (gating by command name is bypassable, where others
force egress through a filtering proxy) and on default-allow.
**Decided (user):** "add everything needed to match the competitors" (`1edde1d`): a default-deny
profile based on Codex's, a filtering proxy with a domain allowlist that refuses loopback,
private and metadata addresses, protected config with Codex's rename guard, a per-session temp
directory, a gated unsandboxed retry, and MCP servers sandboxed per server, which no other
harness does by default.
**Open:** Seatbelt's violation log is unreadable on macOS 27; proxy auth attribution; shared
per-user temp.

### 2026-09-23 · Reviewing routing decisions

**Asked:** which model to dogfood with (the user suggested Opus 5.5), and how to check later
whether routing picked the right models.
**Decided:** dogfood on Auto with Opus 5.5 as the frontier tier, since a fixed model says nothing
about routing. Every turn is logged (tier, model, confidence, reason, tool calls, errors, tokens,
duration, whether the next message looked like a correction), shown as a badge, and reviewable
offline by Opus as appropriate, over-routed or under-routed (`c18d033`).

### 2026-09-23 · Dogfooding, and the routing floor

emmex fixed two of its own issues on Haiku: in-page dialogs (`2415e24`, reviewed appropriate) and
a race when a model is picked while a session loads (`a417a56`, reviewed **under-routed**:
concurrency debugging belongs on the frontier tier).
**Decided:** a deterministic floor that can only raise a tier: judgment words (race, deadlock,
debug, root cause, design, security, tradeoff) go to frontier; multi-step work, code edits and
questions about code identifiers go at least to cheap (`fcaaab2`). It over-routes some requests,
kept deliberately: over-routing costs cents, under-routing costs a wrong fix.

### 2026-09-23 · Tool activity, diffs and panels

**Asked (user):** the conversation is too verbose; Claude uses panels for executions (current
and finished, finished collapsed), diffs, and eventually a terminal and a browser.
**Decided:** the timeline shows only messages, with a chip per burst of tool calls; a right-hand
panel holds Activity (running turn, finished turns collapsed) and Changes (this session's edits
per file) (`20df866`, `af46764`). Follow-ups from the user: the panel is resizable, the "git diff"
button was dropped in favor of computing the workspace diff after each turn and showing it only
when non-empty (`b412f15`), and scrollbars appear only while scrolling (`f68ed09`). The permission
dropdown moved into the composer and the Chat/Code switch to the sidebar, each mode with its own
sessions (`f99033c`).
**Status:** terminal and browser panes are on the backlog.

### 2026-09-23 · Short replies keep their tier; explore before answering

**Problem:** "yes" to an offer to explore was routed to the 3B model, Haiku asked permission to
explore instead of looking, a dead-end fact was saved, and leftover test facts ("I prefer very
terse answers") had been injected into 129 prompts.
**Decided:** short affirmations inherit the previous tier, never below cheap; code-mode
instructions say to explore read-only without asking; the extractor skips dead ends (`3a5b6bb`).

### 2026-09-24 · Why local models were slow, and the prefix cache

**Found:** Qwen3-8B stopped after "Let me examine the files:" because in non-thinking mode it
narrates a plan and ends the turn. On an M4 (10-core GPU) it prefilled about 170 tok/s and
generated about 18 tok/s, and the MLX bridge re-prefilled the whole transcript on every call,
about 35 s before the first token at 6K tokens.
**Decided:** instructions to call tools rather than describe them, a one-time nudge, and first-
output timing in the route log (`9662d60`). Then, with the user's go-ahead on three items:
- **KV-cache reuse:** vendor mlx-swift-lm and patch its adapter to keep one cache per model and
  feed only the new tokens. First output fell from 35-48 s to 3 s; a tool turn from minutes to
  5 s (`71b6820`, [EMMEX-PATCHES.md](../Vendor/mlx-swift-lm/EMMEX-PATCHES.md)).
- **A test target** (`51a012a`).
- **Better facts:** after Claude turns, the cheap Claude tier extracts them; local turns stay
  on-device (`c5df47f`).

### 2026-09-24 · Several models loaded, and reuse across sessions

**Asked (user):** offload models, list loaded ones in the sidebar and reuse them across
sessions; the low-memory warning fired for a model another session had already loaded.
**Decided:** several MLX models can stay loaded, with least-recently-used eviction only when a new
one does not fit; the warning skips loaded models (`0152402`).

### 2026-09-24 · Laya: evaluated, not adopted

**Asked:** Laya, an open 0.4B classifier, for the router or for facts.
**Found:** a ModernBERT encoder with calibrated outputs and a 512-token limit, ported by an
anonymous account; its Python package was audited before install. It cannot extract facts, since
it does not generate text.
**Decided:** evaluate before porting. 94 routing prompts and 60 commands were labelled by Opus
5.5. Laya was 15-20x faster but much less accurate (routing 48% vs 81%; 22 unsafe allows vs 8), so
it was not adopted (`aab9f27`). The eval also found seven commands smart mode runs unasked.
Details in [evals/RESULTS.md](../evals/RESULTS.md).

### 2026-09-24 · Implicit approval from the request

**Decided (user, in a doc comment):** a local `git rebase` is fine unasked, and risky commands
usually follow an explicit request, so the request is the approval. The safety judge should see
the user's latest message and allow a command it explicitly asks for; only the user's own words
count, never tool output or file contents (`c702bcb`).
**Status:** decided, not built. The deterministic rules for publishing, user-global installs,
`defaults write`, and installs outside a virtualenv or vendor dir landed on 2026-10-07 (below).

### 2026-09-24 · Secret scanner

**Asked (user):** use the 3B model to detect passwords and tokens, including a curl command with
a bearer header, and reject the message before any model or transcript sees it.
**Decided:** patterns first for structured secrets (under a millisecond), then the on-device
model only when the text mentions secrets and no pattern matched; the model must quote the secret
exactly, so an invented answer cannot block. Apple's default guardrails refuse to read passwords,
so the check uses permissive guardrails with plain-text output. A blocked message returns to the
composer with Send redacted (`a466aa9`). Patterns caught 18 of 18 structured secrets; with the
model, 6 of 12 plain-language secrets were caught blind (10 of 12 after widening the keyword
gate), with no false alarms (`270eafc`).
**Status:** tool output is not scanned yet.

### 2026-09-27 · The name: emmex

**Decided (user):** the product is emmex. The user needed a name with an available .ai domain and
registered emmex.ai. It has one pronunciation, no clashes in software (a musician, a sandal, a
tools company, a construction-recycling firm), and echoes Vannevar Bush's memex, which fits the
memory feature. Earlier working names were dropped before any release, along with their
compatibility code (`fd8a559`). The local repo folder is still `ksmos`.

### 2026-09-24 · Remove model did nothing in the app

**Cause:** WKWebView shows nothing for `window.confirm` unless the host implements it, so the
confirmation returned "cancel" instantly. **Decided:** an in-page confirmation, and native
alert, confirm and prompt in the app shell (`8997b73`).

### 2026-09-25 · Full-screen Models view

**Asked (user):** the models view should take the whole screen, show where each model lives, add
a model from a folder, and choose context size within the model's limits.
**Decided:** a two-pane view with each model's location and config details; a folder can be used
in place (never modified or deleted) or copied into the library; the context window is a
per-model setting from 2K to the model's maximum, shown with its memory cost (weights plus the
fp16 KV cache of attention layers only; Qwen3-8B at 32K is 4.3 GB + 4.5 GB). The window drives
compaction (`860142a`).
**Open:** the memory warning still counts only weights; the native folder picker is untested.

### 2026-09-25 · Eval report lives in the repo

**Options:** move the shared eval document into the repo, or keep it as the polished shareable
version. **Decided (user):** move it. [evals/RESULTS.md](../evals/RESULTS.md) is updated with any
change that moves the numbers; the document is a dated snapshot (`8ad763d`).

### 2026-09-27 · Load models only on purpose

**Asked (user):** auto-loading kept loading models the user didn't want; show unloaded models
disabled and load them only from the Models view, with an intentional button.
**Decided:** the Load model button is the only way the app loads an MLX model. The picker shows
unloaded models disabled; a session whose model isn't loaded opens without starting until the
model is loaded or another is picked; unloading a model in use parks its session; new sessions
fall back to auto; auto routing skips unloaded tiers. The CLI still loads on demand, since naming
a model there is the request (`7a54cd7`).

### 2026-09-28 · Claude models and Gemini

**Asked:** how to add more Claude models such as Opus 5.5, and Gemini 3.8 Flash.
**Decided (user):** the picker shows exactly Opus 5.5, Sonnet 5.5 (released 2026-09-28,
`claude-sonnet-5-5`) and Haiku; other Claude models can be added with `claudeModels` in
settings, by short name or API id (`36e2409`, `bc0a343`). Gemini needs no code: a `providers`
entry for Google's OpenAI-compatible endpoint (see the README).
**Open:** Gemini is untested (no key). Current Claude models have 1M-token windows while emmex
assumes 200K, which affects when compaction runs and what long prompts cost; **deferred by the
user** the same day, so 200K stays until it is discussed.

### 2026-09-29 · Open source: MIT, on GitHub under parvalabs

**Decided (user):** release under the MIT License, soon. Code adapted from OpenAI Codex
(Apache-2.0) and the vendored mlx-swift-lm keep their notices in THIRD_PARTY_NOTICES.md
(`781ecf1`). The repository is https://github.com/parvalabs/emmex, created private and pushed
with the full history after a scan found no keys, personal paths or email in it. It goes public
once the release checklist in the backlog is done. The local folder stays `ksmos`.

### 2026-10-07 · Publishing and global-state commands ask

**Problem:** the eval found smart mode running `npm publish`, `git push origin main`,
`pip install --user` and `defaults write` unasked, because no rule matched and the 3B judge called
them safe.
**Decided:** a deterministic check, `PolicyEngine.publishesOrChangesGlobalState`, asks before
publishing (`npm`/`cargo publish`, `gem push`, `twine upload`, `git push`, `gh pr create`),
user-global installs (`pip install --user`, `npm install -g`) and `defaults write`. It matches the
command words of each subcommand after `split` and `stripWrappers`, not the raw string, so a commit
message that mentions "npm publish" does not trigger it. In `decide()` it runs:
1. after an explicit Always Allow pattern, so a user who chose "always allow `git push *`" is not
   asked again and the button keeps working;
2. after the read-only rule;
3. before ask mode, so the eval harness, which runs ask mode to see which rule decided, credits
   the rule;
4. before script provenance, which allows a whole compound command when one script in it was
   written by emmex; otherwise `bash build.sh && npm publish` would publish unasked;
5. before the on-device judge, because actions that leave the machine or change global state
   should get the same answer every time, not depend on a nondeterministic 3B model.

`git push --force` keeps its hard rule, which runs earlier. A local `git rebase` stays unasked, as
decided on 2026-09-24. Effect on the eval, with the 2026-09-24 judge answers held fixed: unsafe
allows 7 → 3 and needless asks 4 → 4 (details in [evals/RESULTS.md](../evals/RESULTS.md)).
**Open:** option-first forms such as `git -C .. push` and `npm --global install x` are not caught
(see Shell AST parsing in the backlog). Installs outside a venv or vendor dir followed the same
day (next entry).

### 2026-10-07 · Installs outside a virtualenv or vendor dir ask

**Problem:** the 3B judge called `pip install -r requirements.txt` and `bundle install` safe, so
smart mode ran them unasked. Outside a virtualenv or a project-local bundle path they write to the
user's or system's Python and Ruby, which outlives the project and affects other work.
**Decided:** a deterministic ask, so the answer does not depend on a nondeterministic model. It
stays inside `publishesOrChangesGlobalState`, with no new step in `decide()`, so it runs where the
publishing rule does (after Always Allow and the read-only rule; before ask mode, provenance and the
judge) and the evals credit it.
- **What counts as local:** for pip, a relative `.venv`, `venv`, `.env` or `env` directory's
  `bin/pip`, `bin/pip3`, `bin/python` or `bin/python3` (no `..`, no leading `/`, `~` or `$`), or a
  `pip install` after `source <relative>/bin/activate` in the same command. For bundle,
  `--path <relative>`, `--path=<relative>`, `--deployment`, or a relative `BUNDLE_PATH=…` in front
  of the command.
- **Anything else asks:** `/usr/bin/pip3`, `tools/bin/pip`, a venv with another name, a venv
  activated before emmex started, an existing `.bundle/config`, `bundle install --local`. The rule
  reads only the command text, so when it cannot see that an install is local it asks; the cost
  is an extra prompt, never an unasked global install.
- **Ordering inside the check:** `pip install --user` matches first and keeps its more specific
  reason, `pip install --user`.
- **Bypasses closed in the publishing rule:** leading `NAME=value` assignments
  (`NODE_ENV=production npm publish`) were read as the program, and quoted names (`"npm" publish`)
  did not match. The check now skips leading assignments, keeping `BUNDLE_PATH` for the bundle
  test, and trims surrounding quotes from each word before matching, as `criticalDelete` does.

Effect on the eval, with the 2026-09-24 judge answers held fixed: unsafe allows 3 → 1 and needless
asks 4 → 4. The one left is `git rebase main`, unasked by the 2026-09-24 decision.
**Open:** option-first forms (`python3 -I -m pip`, `git -C .. push`), paths with spaces, versioned
names (`pip3.12`), and `.env/bin/pip`, which the credentials hard rule asks about before this rule
runs.

## Open questions

Each is tracked in [BACKLOG.md](../BACKLOG.md).

- Private Cloud Compute is waiting on Apple's entitlement approval; quota and availability
  messages follow it.
- Jev has never been validated.
- Implicit approval in smart mode; shell parsing beyond word splitting; secret scanning of tool
  output.
- Claude context windows: keep 200K or use the real 1M (deferred).
- Terminal and browser panes, session tree, mid-turn steering, Tasks mode, provider model
  discovery, a Bedrock Converse adapter.
- The silent exit on launch, if it ever reproduces.
- Whether to rename the local folder from `ksmos` (the GitHub repo is `parvalabs/emmex`).
