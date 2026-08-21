# Beet Code — Agent Onboarding

This is a native macOS coding agent (Swift 6 / SwiftUI / MLX + BYOK).

## Before changing anything

1. Read `docs/APP-REPORT.md` — the full structure/capabilities/API/security
   report for this codebase (written for agent reviewers).
2. Read `docs/COMPARISON.md` for known feature gaps vs OpenCode/OpenClaude,
   and `docs/COMPOSER-DESIGN.md` for the composer rationale.
3. Build & test first:
   ```sh
   xcodegen generate   # required after adding/removing files
   xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
     -destination 'platform=macOS' -derivedDataPath .derived test
   ```
   Suite: 370 tests, all deterministic (no weights, no Metal, no network).

## Architecture in 30 seconds

- `AppState` (MainActor) → `AgentSessionController` → `AgentLoop` (actor) →
  `PermissionGate` → `ToolExecutor` → `AgentTool`s.
- Engines behind `LLMEngine`; `EngineRouter` switches local MLX / local GGUF
  (embedded llama-server) / remote BYOK (OpenAI/DeepSeek/LongCat/Alibaba/
  Gemini/OpenRouter/Anthropic/Custom).
- `Workspace` = canonical realpath confinement; `ShellRunner` = posix_spawn
  process groups; `GitCheckpointer` = approval-before-mutation snapshots.
- Sessions encrypted (Keychain key, cached); memory facts/summaries per
  workspace; events stream via AsyncStream<AgentEvent>.
- Models drive the in-app browser (`browser_*` tools → `BrowserController`)
  and the built-in simulator (`sim_*` tools → argent; `sim_build_run` =
  build → install → launch → screenshot → describe in one call).
  `PromptBuilder.capabilityGuidance` teaches models WHEN to use them
  (visual verify loops) — keep it in sync when adding tool families.

## Rules

- Erasable Swift syntax only; NSLock only inside sync helpers (async
  contexts reject lock()/unlock()).
- New tools: implement `AgentTool` (honest `risk` + JSON `schemaText`) and
  register in `AgentSessionController.defaultTools`.
- New settings: `SettingsStore` key + default + SettingsView + pass into
  `AgentLoop.Configuration`.
- Tests: `FakeLLMEngine` / `FixtureHub` / `TempWorkspace`; never real dirs.
- Run `xcodegen generate` after any file add/remove.

## Quick links

- Report: `docs/APP-REPORT.md`
- Gaps: `docs/COMPARISON.md`
- Composer design: `docs/COMPOSER-DESIGN.md`
- Acceptance: `docs/ACCEPTANCE-v0.2.md`

## Cursor Cloud specific instructions

Cursor Cloud Agents run on **Linux x86_64** VMs. Beet Code is a **macOS 15+ /
Apple-Silicon-only** Xcode app, so it **cannot be built, tested, or run in the
Cloud Agent environment**. Treat the cloud VM as read/edit/review only; do all
build/test/run verification on a macOS host or in CI.

Why it can't run here (verified, not assumed):

- Build system is `xcodegen` + `xcodebuild` (macOS-only). There is no
  `Package.swift`, so SwiftPM can't build it either.
- `project.yml` pins `ARCHS: arm64`, `EXCLUDED_ARCHS: x86_64`, `macOS 15.0`,
  `CODE_SIGN_IDENTITY: "Apple Development"`. The cloud VM is x86_64 Linux.
- `Core` + `App` import Apple-only frameworks throughout (`SwiftUI`, `AppKit`,
  `WebKit`, `Security`/Keychain, `MLX`/`MLXLLM`/`MLXVLM`/`MLXLMCommon` (Metal),
  `CoreServices`, `CoreGraphics`, `ApplicationServices`). A Linux Swift
  toolchain typechecks pure-`Foundation` files but fails these with
  `error: no such module 'AppKit'` (also `Security`, `MLX`, …).
- CI is macOS-only: `.github/workflows/macos.yml` runs on `runs-on: macos-15`.

Do NOT try to install a Swift-for-Linux toolchain to build the project — it
cannot resolve the Apple frameworks and there is no SwiftPM manifest, so it
produces nothing runnable. The startup update script is intentionally a no-op.

Canonical build/test commands (run on macOS only) live in the top of this file
and in `.github/workflows/macos.yml`; don't duplicate them.