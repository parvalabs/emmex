# emmex: working on this repo

emmex is a Swift, UI-first Mac agent harness on Apple's FoundationModels (macOS 27). Read
`README.md` for features, `docs/DECISIONS.md` for why things are the way they are, `BACKLOG.md`
for pending work. The code is at https://github.com/parvalabs/emmex (private until release);
the local folder is still named `ksmos`.

## Build and test

Requires macOS 27, Xcode 27 with its Metal Toolchain component, and Apple Intelligence enabled;
the step-by-step setup is in the README's Setup section.

```bash
swift build                          # everything; the CLI is .build/debug/emmex
swift test                           # unit tests (Swift Testing), must pass before committing
swift build -c release               # use for timing MLX; debug MLX builds are very slow
scripts/bundle-app.sh debug          # the Mac app at .build/Emmex.app
```

Debug commands that exercise one subsystem without running a model turn:
`emmex policy -- "<cmd>"` (permissions), `emmex sandbox -- "<cmd>"`, `emmex route -- "<prompt>"`,
`emmex secrets -- "<text>"`, `emmex memory list|search|relate`, `emmex sessions routes <id>`.
Classifier evals: see `evals/README.md`; results in `evals/RESULTS.md`.

## Test the UI in the built-in browser

The UI is HTML/CSS/JS served by the app and shown in a `WKWebView`. It was chosen over a
native SwiftUI interface mainly so an agent can drive and verify it: the same UI runs in a
browser, where Claude can click, type, read the DOM and inspect state, then fix the code and
reload. Screen recording is not granted on this Mac, so native screenshots are not an option.

1. Serve the UI with live assets, on a scratch workspace rather than a real project:

   ```bash
   .build/debug/emmex serve --port 8765 --workspace <scratch-dir> --web-root Sources/EmmexServer/Resources/web
   ```

   With `--web-root`, edits to `app.js`, `app.css` and `index.html` apply on reload; Swift
   changes need a rebuild and a server restart.
2. Open `http://localhost:8765/` in Claude's built-in browser pane (the `Claude_Browser`
   tools: `preview_start` with the URL, or `navigate`).
3. Prefer `read_page`, `find` and `get_page_text` over screenshots. `javascript_tool` can read
   the page's state object `S` (the server snapshot) and call UI functions.
4. Script the server directly when that is simpler: `GET /state` returns the snapshot,
   `POST /action` takes `{"type": "...", ...}` (the cases in `AppController.handle`),
   `GET /events` is the SSE stream, `GET /debug` counts connected clients.
5. Check the console for errors (`read_console_messages`) after each change.

To check the real app: launch a copy with `open -n .build/Emmex.app --env KEY=value`; running
the binary directly opens no window. Useful variables: `EMMEX_WORKSPACE`, `EMMEX_PORT`,
`EMMEX_WEB_ROOT`, `EMMEX_AUTOPROMPT`, `EMMEX_DEBUG` (logs to stderr), `EMMEX_USAGE` and
`EMMEX_AUDIT` (CLI), `EMMEX_SANDBOX_DEBUG` (prints the Seatbelt profile),
`EMMEX_MLX_PROMPT_CACHE=0` (disables KV-cache reuse).

## Testing without harming real data

- Keep test sessions, memories and models out of the user's data: use a scratch workspace,
  delete throwaway sessions (`delete_session` action), and `emmex memory forget` test facts.
- To test model removal or folder import, create a fake model folder (a copied `config.json`,
  an empty `model.safetensors`, a `tokenizer.json`); never remove the user's models.
- In the app, MLX models load only from the Models view; loading an 8B model takes about 5 GB.
- Model calls cost money and time: prefer the on-device `system` model or `claude:haiku` for
  checks, and one-line prompts such as `Reply with exactly: OK`.

## Conventions

- Conventional Commits (`type(scope): summary`), split by concern.
- Pending work goes in `BACKLOG.md`, dated, moved to Done with its commit hash.
- Decisions go in `docs/DECISIONS.md` in the same commit as the work.
- Eval numbers in `evals/RESULTS.md` are updated with any change that moves them.
- Secrets live in the macOS Keychain (`emmex-anthropic`, `emmex-<provider>`); never print them
  or write them to files. Test secrets are built at runtime (`EvalHarness.fixture`).
- Don't answer macOS permission dialogs (screen recording, admin prompts); ask the user.
- `Vendor/mlx-swift-lm` is a patched copy; record changes in its `EMMEX-PATCHES.md`.
