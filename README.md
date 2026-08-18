# Beet Code

A lightweight, native, **Apple Silicon-only macOS coding agent**. BeetCode runs MLX models in-process through Metal, downloads them directly from Hugging Face with pause/resume, and gives a local coding agent safe, reviewable tools.

> Phase 1 deliberately focuses on one polished path: MLX + MLX-quantized safetensors + core coding tools. GGUF/llama.cpp and MCP are planned follow-ups, not half-implemented dependencies.


## v0.2 — safety, durability, diagnostics

Implemented and verified by the test suite (`xcodebuild … test`, 120+ tests,
no model weights or Metal needed):

- **Workspace confinement**: canonical realpath containment (symlink-safe,
  `/private/var`-consistent), per-operation intent, resolved-path reuse,
  bounded reads, excluded-descendant skipping.
- **Shell policy**: exact safe-command auto-approval (operators, substitution,
  redirection, backgrounding, and outside paths always ask); sanitized
  environment without Git override variables; process-group kill on
  timeout/cancel; typed command results.
- **Checkpoints**: sanitized git environment, foreign-tree rejection, tree
  retention under local refs (GC-safe), per-workspace serialization, index
  preservation on restore, symlink-safe cleanup, newline-safe paths.
- **AgentLoop**: run-state guard, one-shot stream completion, cancellation
  mapping, request-scoped approvals, one-tool-call protocol enforcement,
  assistant/tool-result history pairing, checkpoint-before-mutation with
  failure surfacing, deterministic fake-engine suite.
- **Durability**: encrypted (Keychain-key) sessions with redaction and
  bounded retention; AppPreferences restore with validation; download
  manifests with pause → quit → relaunch → resume; repair of stale model
  registry entries; memory-pressure model dumps clear the UI state.
- **Diagnostics**: `build_diagnostics` tool with Swift/Xcode output parsing,
  grouped-by-file UI, and optional post-edit verification that always runs
  through the approval path.
- **Repository context**: bounded workspace index respecting ignore rules and
  vendor exclusions, with per-file symbol summaries in the system prompt.

Manual acceptance checklist: [`docs/ACCEPTANCE-v0.2.md`](docs/ACCEPTANCE-v0.2.md).

## v0.3 — BYOK, simulator, memory, reasoning

- **BYOK remote engines**: OpenAI, DeepSeek, LongCat, Alibaba DashScope,
  Gemini, and OpenRouter — Keychain-backed API keys, provider/model settings,
  and a Model Manager section to switch between the local MLX engine and a
  remote provider. The agent loop is engine-agnostic.
- **Built-in iOS Simulator side panel**: docked next to the chat (toolbar
  toggle), with device list, boot/shutdown, app install/launch, and a live
  screenshot stream (public `simctl` APIs).
- **argent integration**: when `argent` is installed, the agent gets
  `sim_list_devices`, `sim_boot_device`, `sim_launch_app`, `sim_tap`,
  `sim_swipe`, `sim_type`, `sim_describe`, and `sim_screenshot` tools to
  drive the simulator — tap/swipe/type go through the normal approval card.
- **Vision**: `describe_image` tool using vision-capable BYOK providers
  (OpenAI / Gemini / OpenRouter). A local SmolVLM engine plugs into the same
  seam once mlx-swift-lm ships VLM support.
- **Memory**: Mem0/Letta-style per-workspace memory with modes (off /
  session summaries / facts / full); durable facts plus earlier-session
  summaries are injected into the system prompt with keyword relevance
  ranking; the agent can maintain facts with `memory_add`/`memory_delete`.
- **Compression options**: light / standard / aggressive context compaction
  (assistant/tool-result pairing always preserved).
- **Reasoning toggle**: show or hide `<think>` chain-of-thought blocks
  (local Qwen3 and remote reasoning models, whose `reasoning_content` is
  folded into think blocks).
- **Thermal fix**: `ProcessInfo.thermalState` alone stays `.nominal` on
  warm Apple Silicon Macs; a CPU-load proxy (public `host_processor_info`)
  now escalates the effective state under sustained load, so the status bar
  and throttling reflect real warmth.
- **UI**: animated Copilot-style composer with configurable flow presets,
  streaming cards with a typing indicator, richer approval cards, and
  diagnostics with breadcrumbs and grouped-by-file presentation.
## v0.4 — hardening and agent competitiveness

- **Restored-session seed**: continuing a restored session seeds the loop
  with the persisted record so history and checkpoints carry over.
- **Simulator off the main actor**: `SimctlRunner` runs simctl through the
  process-group shell runner (hard timeouts, cancellation); the panel state
  lives in `@MainActor SimulatorContext`.
- **Stronger confinement**: the workspace root is re-validated on every
  path resolution; symlink/prefix checks were hardened with more tests.
- **Remote switch unloads local**: activating a BYOK provider explicitly
  unloads the resident MLX model first.
- **Hard tool timeouts everywhere**: git, rg, argent, and simctl all run
  through `ShellRunner` (posix_spawn + process group + kill on timeout).
- **Build to install to launch to screenshot to inspect**: `sim_build_run`
  runs the full loop in one tool call (xcodebuild, simctl install/launch,
  screenshot, vision describe), so the agent can verify UI work end to end.
- **Verification before completion**: with verification enabled, a failing
  build-diagnostics pass refuses `attempt_completion` and feeds the errors
  back until the build is clean.
- **Failure classification**: tool failures carry typed tags
  (`[timeout]`, `[command exit N]`, `[workspace]`, etc.) so the model and UI
  can react without string-sniffing.
- **Agent phase state machine**: planning, awaiting plan approval, working,
  awaiting approval/question, verifying, finished - surfaced in the UI.
- **Task-ranked repo context**: the workspace index ranks files by task
  relevance so the prompt leads with what matters.

## v0.5 — local API server + concurrency hardening

- **OpenAI-compatible local API server**: `Core/Server/LocalAPIServer` is a
  zero-dependency HTTP/1.1 server over POSIX sockets, bound to 127.0.0.1
  only (nothing outside this Mac can reach it). Routes: `GET /v1/models`,
  `POST /v1/chat/completions` (streaming SSE + non-streaming), `GET
  /health`, CORS for browser clients. The endpoint is **stateless**: every
  request resets the engine session and replays the full conversation, so
  Codex `--oss`, Claude Code, Aider, or any OpenAI-format client can drive
  BeetCode's loaded model. Toggle it in Settings → General → Local API
  Server (port configurable, status dot, copy-curl-example), or run it
  headless with `lf serve [--port N] [--model <catalog-id>]`.
- **Keychain deadlock chain eliminated (F9/F9b/F9c)**: session
  encryption previously held the store mutex across `SecItemCopyMatching`
  — an invisible Keychain prompt (which ad-hoc re-signed builds trigger
  after every binary change) froze the app and the test host. All
  Keychain access now (1) runs outside locks, (2) fails fast with
  `kSecUseAuthenticationUISkip` and a visible one-click "Unlock" banner in
  the sidebar, and (3) uses a deterministic in-process key under XCTest so
  the suite never touches securityd.
- **Layering fix**: `ComposerFlow` and `SimctlRunner` moved from App to
  Core so the CLI target compiles (it previously didn't).
- **Settings**: Local API Server card; composer style + animated-border
  toggle moved out of the chat toolbar into Settings → General.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 15+
- Xcode 26.5+ / Swift 6
- XcodeGen (`brew install xcodegen`)
- 8 GB Macs: Qwen3 1.7B is the recommended first model; 4B is marginal; 7B+ is refused by the admission gate on this tier.

## Build

```sh
xcodegen generate
xcodebuild -project BeetCode.xcodeproj \
  -scheme BeetCode \
  -destination 'platform=macOS' build

xcodebuild -project BeetCode.xcodeproj \
  -scheme BeetCode \
  -destination 'platform=macOS' test
```

The CLI harness builds alongside the app:

```sh
xcodebuild -project BeetCode.xcodeproj \
  -scheme BeetCodeCLI \
  -destination 'platform=macOS' build

# The binary is in Xcode DerivedData/Build/Products/Debug/BeetCodeCLI
lf status
lf download qwen3-1.7b-4bit
lf generate qwen3-1.7b-4bit 'Explain actors in one sentence.'

# Serve the model over an OpenAI-compatible local API (loopback only):
lf serve --port 1234 --model qwen3-1.7b-4bit
#   → POST http://127.0.0.1:1234/v1/chat/completions
```

## Architecture

```
SwiftUI
  └── AppState / AgentSessionController       UI boundary
        ├── ModelDownloadManager
        │     └── HFHubClient → SmartFileDownloader
        ├── MLXEngine → GenerationGate        in-process Metal inference
        │              └── MemoryAdvisor
        ├── ThermalMonitor / MemoryPressureCoordinator
        └── AgentLoop
              └── PermissionGate → ToolExecutor → core tools
```

The UI never directly manipulates MLX, files, or shell commands.

### Inference

- `mlx-swift-lm` 3.x (`MLXLLM`, `MLXLMCommon`) and `mlx-swift` are Swift Package Manager dependencies.
- `MLXEngine` loads a local model directory with `LLMModelFactory` and `HFTokenizerLoader`.
- `GenerationGate` serializes every Metal operation and queues cache clears until generation is idle. This avoids MLX's process-killing concurrent-command-buffer failure mode.
- Streaming uses `ChatSession` and Swift concurrency.

### Memory and thermal safety

`MemoryAdvisor` is the single model-load authority:

- Measures `phys_footprint`, not `resident_size`.
- Uses a 70% usable-RAM budget, 1.3× working-set overhead, and a configurable 500 MB headroom reserve.
- Verdicts: fit (<60%), marginal (60–90%), won't fit (>90%).
- Memory pressure warning clears MLX caches; critical pressure dumps the model only when this process is low on headroom, then blocks reloads for 20 seconds.
- Thermal hysteresis: 8 seconds heating / 15 seconds cooling; critical is immediate.
- Serious thermal state caps generation at 1,536 tokens; critical blocks new loads and caps at 512.

### Hugging Face downloads

- Token is stored in the macOS Keychain, never UserDefaults.
- Hub tree listing fetches file size, ETag, LFS SHA-256, and commit metadata.
- Each file uses explicit `Range: bytes=N-` requests and an `.incomplete.json` sidecar containing ETag, offset, total size, and expected digest.
- Pause survives app termination and resumes after a fresh ETag check; an HTTP 200 response to a resumed request correctly truncates and restarts.
- LFS files are SHA-256 verified before atomic rename; retries use exponential backoff with jitter; disk space is checked before transfer.
- The model manager downloads files sequentially so memory stays predictable and progress is easy to explain.

### Agent safety

The loop is:

```
generate → parse → PermissionGate → approval → Git checkpoint → execute → observe → repeat
```

Built-in tools:

- `read_file` (line-numbered, bounded, binary detection)
- `list_directory` (git/build directory filtering)
- `search` (`rg` when available, Swift fallback)
- `apply_patch` (exact SEARCH/REPLACE blocks)
- `write_file` (read-before-write enforcement)
- `run_command` (sanitized environment, bounded output, hard timeout)

Reads run automatically. Writes and commands need approval by default; approval cards show the exact command or diff. Command prefixes can be allowlisted in Settings.

Before the first approved write in a turn, `GitCheckpointer` snapshots the working tree using a temporary Git index. Restore also removes only newly-created untracked paths absent from the snapshot — never broad `git clean`.

The parser is engine-independent and accepts fenced tool JSON, Qwen `<tool_call>` tags, OpenAI `tool_calls` envelopes, comments, single quotes, trailing commas, and arguments encoded as a JSON string.

## Models

The bundled catalog currently includes:

- `qwen3-1.7b-4bit` — recommended for 8 GB
- `qwen3-4b-4bit` — 8–12 GB (marginal on 8 GB)
- `qwen2.5-coder-7b-4bit` — 16 GB
- `qwen3-8b-4bit` — 16 GB
- `qwen3-coder-14b-4bit` — 24 GB
- `qwen3-coder-30b-a3b-4bit` — 32 GB+

Catalog entries are ordinary Swift values; adding a user model later does not require changing the engine.

## Current limitations

- The app currently targets MLX-quantized safetensors, not GGUF.
- Native MCP client support is intentionally deferred until the core tool workflow is stable.
- The model manager currently downloads repo snapshots sequentially; per-file range resume is implemented, while parallel chunk fetching is a future optimization.
- The in-process engine is intentionally single-resident; the safety coordinator unloads before admitting another model.

## Open-source dependencies

- [mlx-swift](https://github.com/ml-explore/mlx-swift) — MIT
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — MIT
- [swift-transformers](https://github.com/huggingface/swift-transformers) — Apache-2.0

The design was informed by the memory, thermal, downloader, and lifecycle patterns in [Mesutcydev/ios-local-llm](https://github.com/Mesutcydev/ios-local-llm), an MIT-licensed reference project.