# ROKUBI Harness — Agent & Contributor Notes

Native macOS build of the ROKUBI Harness (PRD v0.4). SwiftUI + AppKit, Swift 6, Xcode 26,
macOS 15+. Monaco runs in a `WKWebView`; the agent talks to OpenAI's Responses API via
ChatGPT sign-in (OAuth/PKCE) or an API key, or to OpenRouter over Chat Completions, all behind `AuthProvider`.
User-facing overview: `README.md`.

## Build & run
- `scripts/bootstrap.sh` — one-time: fetches XcodeGen (into `.tools/`) and `npm ci` for Monaco.
- `scripts/build.sh [Debug|Release]` — builds the Monaco bundle, runs XcodeGen, then `xcodebuild`.
  Uses `-skipPackagePluginValidation`; the project (`RokubiHarness.xcodeproj`) is generated and gitignored.
- `scripts/test.sh` — `swift test` for every package under `Packages/`.
- `scripts/run.sh` — build Debug and launch.
- `scripts/package.sh [--install]` — Release build copied to `./RokubiHarness.app` (and `/Applications`).
- `scripts/smoke.sh [--openrouter]` — end-to-end run against the offline mock (see below).

## Architecture
- `Packages/HarnessCore` — workspace, file service, ignore rules, file watcher, search, patch
  applier, checkpoints, git service, diagnostics parser. No UI, no AppKit dependency beyond Foundation.
- `Packages/HarnessAgent` — model adapters (ChatGPT OAuth, OpenAI API key, OpenRouter), SSE +
  Responses/Chat Completions clients behind the `LLMClient` seam, tools, permission engine,
  orchestrator, context assembler, skills. UI-agnostic.
- `Packages/HarnessEditor` — Monaco `WKWebView` bridge (`MonacoController`, typed messages).
- `Packages/HarnessTerminal` — PTY process, ANSI line buffer, terminal sessions, command runner.
- `Packages/HarnessUI` — all SwiftUI surfaces + `AgentSession` (per-window state).
- `App/` — `@main`, windows, menus, command palette wiring.
- `Web/monaco/` — the Monaco bundle source (esbuild → `dist/`, copied into the app at build).

## Conventions
- Keep `HarnessCore`/`HarnessAgent` free of SwiftUI so they stay testable and reusable.
- Swift 6 strict concurrency is on. Long work runs in actors; `@Observable` view state is `@MainActor`.
- **Never read the Keychain, spawn a subprocess, or block on I/O inside a SwiftUI `body`** — it
  causes AttributeGraph cycles or launch stalls. Defer to first async use (see `APIKeyAuth.ensureLoaded`).
- Avoid competing flexible-height frames in one `VStack`; give contextual panels explicit heights.
- Providers declare `api: ModelAPIStyle`; `AgentSession` picks `ResponsesClient` (OpenAI) or
  `ChatCompletionsClient` (OpenRouter / any OpenAI-compatible endpoint) per turn. Both normalize to
  `ResponseStreamEvent`, so the orchestrator never sees the difference.
- The app never picks a model. `ModelCatalog.selected` is nil until the user chooses one. Each account type keeps its own
  choice under `model.userSelected.<chatGPT|apiKey|openRouter>`. `WorkspaceView` calls `setAccount` whenever the account
  changes, which restores that choice (and resets the model list) without writing anything; only `select(_:)` saves.
  A refresh never replaces the choice, and the composer won't send without one.
- All OpenAI/ChatGPT/OpenRouter constants live in `OpenAIEndpoints.swift`. The ChatGPT backend is undocumented —
  re-verify against `openai/codex` (`codex-rs/login`) if auth breaks.
- The agent may only touch files through `FileService`; secrets (`.env`, `*.key`, …) are blocked
  for agent reads. Every mutating tool checkpoints before writing.

## Testing the agent loop offline
- `scripts/smoke.sh [--openrouter]` — the end-to-end check. Builds Debug, starts `scripts/mock-openai.py`,
  opens a copy of `demo-project/` (a cart with one deliberate bug and one failing test), lets the scripted
  agent plan → run tests → patch `src/cart.js` → re-run tests → report, then asserts the file changed and
  `npm test` passes. Screenshot at `DerivedData/smoke-<flavour>.png`. `SMOKE_SKIP_BUILD=1` reuses the build.
- `scripts/mock-openai.py` is the scripted Responses API mock (also serves `/chat/completions` for OpenRouter mode).
  Its patch replaces `total()` verbatim, and `DEMO.html` shows that same code, so keep `demo-project/src/cart.js`
  byte-identical to `BUGGY_TOTAL` in the mock. If `npm test` passes in `demo-project`, the smoke test aborts.
- Manual: `open -n DerivedData/Build/Products/Debug/RokubiHarness.app --args --project <dir> --base-url http://127.0.0.1:8765 --api-key test --model gpt-5.4 --prompt "…"`.
  Launch through `open -n`, not the raw binary: from a non-interactive shell the raw binary may never get a window.
- Flags in every build: `--project <dir>`, `--open <file>`.
- Debug-only flags: `--snapshot <png>` (+ `--snapshot-delay=<s>`, `--quit-after-snapshot`), `--base-url`, `--api-key`,
  `--openrouter-key`, `--model <id>`, `--prompt`. `--api-key`/`--openrouter-key` skip the Keychain entirely. `--model`
  sets the model for that run without saving it; `--prompt` sends nothing unless a model is chosen or passed.
- Builds are ad-hoc signed, so every rebuild is a "new" app to the Keychain: the first launch of a fresh build
  that restores a stored key shows a Keychain access prompt (or, from a sandboxed/headless shell, blocks in
  `SecItemCopyMatching` in the background restore task). Expected; it's why smoke runs pass keys via flags.

## Docs
- `README.md` (GitHub landing page), `TUTORIAL.html` (field guide), `DEMO.html` (demo replay) describe
  user-visible behaviour. Update them when you add, rename, or remove a button, command, shortcut, or panel.
- `DEMO.html` quotes real terminal output from `demo-project`; regenerate it if the tests or the bug change.

## Security boundary (what the agent can and cannot do)
- Paths: `FileService.contains` resolves symlinks on both sides, so a link inside the project pointing outside
  is rejected; `isProtected` checks the basename of the link *and* its target. `rename_path`/`delete_path`
  refuse protected files (otherwise `.env → x.txt` then `read_file` would work).
- Commands: `PermissionPolicy.hardDenyCommandPatterns` are regexes matched anywhere in the line (force push,
  `rm -rf /|~|$HOME`, `sudo`/`doas` in command position, `mkfs`, `dd of=/dev/…`, fork bomb…). Rules for the
  `run`/`packageInstall` classes use `CommandPattern` (`*` spans `/` and spaces); path classes use `Glob`.
  This is a backstop, not a sandbox — `run_command` goes through a login shell.
- `.rokubi/permissions.json` ships with the repo, so a blanket `allow` (no `match`) for anything beyond
  reads is ignored; scoped allows like `npm test*` work.
