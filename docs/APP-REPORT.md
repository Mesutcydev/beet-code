# Beet Code — Application Information Report

> Purpose: a precise, current description of BeetCode's structure,
> capabilities, key APIs, security model, test strategy, and known gaps —
> written so another agent (or engineer) can review, onboard, and improve
> the app without re-deriving everything from source.

> **Addendum (2026-08-19, v0.8):** since this report was written the app
> gained: the embedded GGUF/llama.cpp engine with KV-aware context admission
> (fixed 32 K clamp removed) and auto-enabled MTP speculative decoding; the
> left activity rail (panel toggles + new-chat) replacing the chat toolbar;
> Claude/Codex/Cursor chat-history import with live parser status and
> project-grouped collapsible sidebar headers; a Plugins settings tab;
> workspace-history digest in the system prompt; light/dark/beet themes with
> full-UI beet tint; local SmolVLM vision models in the catalog. Details in
> `README.md` (v0.8) and `docs/MTP-FEASIBILITY.md`; sections below describing
> the pre-v0.8 UI are historical.
>
> **Addendum (2026-08-21, interoperability):** Cursor chat import now reads
> the current global `composerHeaders` + indexed composer/bubble records and
> retains the legacy workspace-database fallback. The Skills/Plugins settings
> surface discovers Claude Code, Codex, Cursor, Copilot, Windsurf, OpenCode,
> and Agent Skills conventions, including declarative skills inside plugin
> bundles. Users can connect any additional IDE/plugin folder; files stay in
> place and executable installers or hooks are never run during import.
>
> **Addendum (2026-08-21, signing and device delivery):** Ship Center can use
> a valid Apple code-signing identity already held by macOS Keychain, create a
> signed iOS archive and IPA with current Xcode export methods, and install the
> finished app on a connected physical iPhone or iPad through `devicectl`.
> The composer provides a native setup sheet for certificate, provisioning,
> export, and device choices. Certificate passwords and private-key material
> never enter Beet Code; `.p12`/`.pfx` imports are handed to Keychain Access.
>
> **Addendum (2026-08-21, history UX):** the sidebar now presents a compact
> `My chats` / `Other tools` switch with one shared search field. Imported
> conversations are grouped by project instead of vendor, carry clear Claude,
> Codex, Cursor, or bundle badges, and expose Import as the primary action only
> in the relevant view. Existing imports no longer trigger an automatic rescan
> every time the user revisits them.
>
> **Addendum (2026-08-21, v0.9.4 native readiness):** a compact first-run
> assistant now connects the workspace and model, checks Apple Silicon,
> macOS, Xcode, Keychain signing identities, and connected devices, and offers
> direct recovery actions from empty states. Ship Center can additionally ask
> Xcode to upload an eligible iOS archive to App Store Connect. The full
> deterministic suite now executes 710 tests with 1 intentional skip and no
> failures.
>
> **Addendum (2026-08-21, runtime capability map):** every agent prompt now
> places a compact, task-oriented capability map before the large tool-schema
> catalog. The map is generated from the exact per-session registry, includes
> connected MCP tools, remains present in memory-safe local mode, and never
> names unavailable sibling tools. Project instructions, policy, memory, and
> edit rules also precede bulky schemas so prompt fitting cannot silently
> discard them first. The full deterministic suite now executes 714 tests
> with 1 intentional skip and no failures.
>
> **Addendum (2026-08-22, v0.9.5 release readiness):** encrypted session
> save failures are now surfaced and retained for retry; computer control is
> opt-in; Model Manager recommends chat and vision models for the Mac's chip
> and unified-memory tier; chat, sidebar, and settings code is split into
> focused components; and the app has launch-level accessibility smoke
> coverage. The verified suite executes 738 unit tests with 2 intentional
> opt-in skips plus 3 UI tests, with no failures.
>
|> **Addendum (2026-08-19, prompt capability guidance):** the in-app browser
|> (README v0.6) and the simulator tools were registered but the system prompt
|> never told models WHEN to use them. `PromptBuilder.capabilityGuidance` now
|> derives its runtime map from the registered tool list: browser tools teach
|> an observe/action/verification loop; simulator tools teach `sim_build_run`
|> as the one-shot build → install → launch → screenshot → describe loop plus
|> the granular `sim_*` controls. Covered by
|> `Tests/PromptCapabilityGuidanceTests.swift`.
|>
|> **Addendum (2026-08-19, remaining-audit pass):** `glob` is an alias of
|> `find_files`; `web_fetch` is an approval-gated bounded HTTP GET; session
|> token/cost totals show in the status bar; `task` is a read-only nested
|> agent (8 turns, IsolatedReplayEngine so the parent conversation is not
|> reset). EnginePool holds up to 4 local models. See `docs/AUDIT-2026-08-19.md`
|> and `docs/COMPARISON.md`.

## 1. Identity

- **What**: native macOS (Apple Silicon only) coding agent that runs MLX
  models in-process (Metal) and/or remote BYOK providers, with a
  permission-gated tool loop, git checkpoints, durable encrypted sessions,
  long-term memory, an iOS Simulator panel with argent device tools, and a
  Cursor-style composer.
- **Stack**: Swift 6.0 (erasable syntax only), SwiftUI, macOS 15+ target,
  XcodeGen (project.yml), Swift Package Manager deps: mlx-swift-lm 3.31.4,
  mlx-swift 0.31.6, swift-transformers 1.3.3, swift-huggingface 0.9.0
  (pinned in BeetCode.xcodeproj/.../Package.resolved).
- **Targets**: `BeetCode` (app: App + Core), `BeetCodeCLI` (Core + CLI),
  `BeetCodeTests` (Tests, app-hosted).

## 2. Build / test

```sh
cd BeetCode
xcodegen generate                     # after adding/removing files
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' -derivedDataPath .derived build
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' -derivedDataPath .derived test
```

Current suite: **738 unit tests executed, 2 intentionally skipped, plus 3 UI tests; 0 failures**.
Tests never need model weights or Metal (FakeLLMEngine + FixtureHub).

## 3. Directory map

| Path | Responsibility |
| --- | --- |
| App/BeetCodeApp.swift | App entry; adaptive window min-width; Model Manager command |
| App/AppState.swift | Single UI door to services; engine router; model/download lifecycle; launch restore; thermal task |
| App/AgentSessionController.swift | AgentLoop↔SwiftUI bridge: transcript, approvals, plan, questions, git controls, attachments, session restore |
| App/ChatView.swift | Transcript UI, hybrid composer (attachments, expanding input, accessory row), plan/reasoning/streaming cards, diagnostics breadcrumbs |
| App/MainWindowView.swift | NavigationSplitView: sidebar (workspace, git, sessions), detail (chat + docked simulator panel) |
| App/ModelManagerView.swift | Download/install/activate models; BYOK remote section |
| App/SettingsView.swift | HF token, autonomy, generation, memory & context, advanced, launch, BYOK providers |
| App/SimulatorController.swift / SimulatorPanelView.swift | SimulatorContext (@MainActor) + SimctlRunner (off-main, ShellRunner-backed); docked side panel |
| App/BrowserPanelView.swift + Core/Browser/BrowserController.swift | Agent-controlled in-app browser: shared WKWebView, extraction via JS snippets, JS-escaping security boundary |
| App/ComposerStyle.swift / ComposerAttachment.swift | Composer flow presets + attachment model |
| App/StatusBarView.swift | RAM/thermal/model/tok-s status |
| Core/Agent/AgentLoop.swift | The actor orchestrating generate → parse → gate → checkpoint → execute |
| Core/Agent/AgentTypes.swift | AgentEvent, AgentFinish, ToolInvocation, ApprovalRequest, PendingRequest |
| Core/Agent/ToolParser.swift | Model text → ParsedToolCall (fenced/Qwen/OpenAI/bare JSON) |
| Core/Agent/ToolExecutor.swift | Runs tools; typed outcomes; duplicate-registration guard |
| Core/Agent/PermissionGate.swift | Auto/needsApproval decisions (reads auto; writes/commands ask) |
| Core/Agent/PromptBuilder.swift | System prompt; exact runtime capability map before schemas; repo index + memory + plan-mode sections; think-block strip/extract |
| Core/Agent/ContextCompactor.swift | CompressionLevel (light/standard/aggressive) + token-aware compaction |
| Core/Agent/GitCheckpointer.swift | Snapshot/restore with temp index, GC refs, index preservation, foreign-tree rejection |
| Core/Agent/AgentMemory.swift / MemoryTools.swift | Per-workspace facts + summaries; memory_add/memory_delete |
| Core/Agent/RepoIndex.swift | Bounded workspace index with ignore rules + symbol summaries |
| Core/Agent/ControlTools.swift | ask_user / attempt_completion control tools |
| Core/Tools/AgentTool.swift | AgentTool protocol, ToolRisk, Workspace (canonical confinement), ToolContext |
| Core/Tools/FileTools.swift | read_file (bounded), write_file, list_directory |
| Core/Tools/ApplyPatchTool.swift | SEARCH/REPLACE patch engine (pure, unit-tested) |
| Core/Tools/SearchTool.swift | rg-first content search with descendant skipping |
| Core/Tools/RunCommandTool.swift | run_command with typed CommandResult (CommandExecuting) |
| Core/Tools/CommandPolicy.swift | Safe-command auto-approval rules + mutation classification |
| Core/Tools/ShellRunner.swift | posix_spawn process-group runner (chdir, sanitized env, kill on timeout/cancel) |
| Core/Tools/BuildDiagnosticsTool.swift | Build + DiagnosticParser (Swift/xcodebuild output) |
| Core/Tools/SimBuildRunTool.swift | sim_build_run: detect project → xcodebuild → install → launch → screenshot → describe (P1 build loop) |
| Core/Tools/ArgentBridge.swift / SimulatorAgentTools.swift | argent CLI bridge + sim_* device tools |
| Core/Tools/BrowserTools.swift | browser_* tools: read/screenshot auto-approved; navigate/click/type/eval approval-gated |
| Core/Tools/VisionTool.swift | VisionProvider (BYOK describe_image) + DescribeImageTool; SmolVLM seam |
| Core/Inference/LLMEngine.swift | Engine protocol + default cache/dump impls |
| Core/Inference/MLXEngine.swift | MLX ChatSession engine behind GenerationGate |
| Core/Inference/RemoteLLMEngine.swift | EngineRouter (local↔remote switch); RemoteLLMEngine over OpenAI-compatible/Gemini |
| Core/Inference/RemoteLLMClient.swift | SSE streaming client; reasoning_content folding |
| Core/Inference/LLMProvider.swift | 6 providers + APIKeyStore (Keychain, cached) |
| Core/Inference/ThermalMonitor.swift | Kernel thermal + CPU-load proxy with hysteresis |
| Core/ModelManager/* | ModelStore (registry+repair), ModelDownloadManager (manifests), SmartDownloader (range/sidecar), HFHubClient (HubServing), HFTokenStore (Keychain), MemoryAdvisor, MemoryPressureCoordinator |
| Core/Persistence/SessionStore.swift | SessionRecord + SessionCrypto (AES-GCM, Keychain key, cached) + redaction |
| Core/Persistence/AppPreferences.swift | Durable selections (workspace/model/session/auto-resume/remoteModel) |
| Core/Persistence/SettingsStore.swift | UserDefaults settings (keys listed in §8) |
| Core/Support/* | Log (os.Logger), ByteFormatter, DiffEngine, LFJSON (lossless JSON) |
| CLI/BeetCodeCLI.swift | CLI harness (status/download/generate) |
| Tests/TestSupport/* | FakeLLMEngine, EventCollector, TempWorkspace, GitRepo, FixtureHub |
| docs/* | COMPARISON.md, COMPOSER-DESIGN.md, ACCEPTANCE-v0.2.md |

## 4. Architecture & data flow

```
SwiftUI views → AppState (MainActor) → AgentSessionController → AgentLoop (actor)
                                                        │
              generate (LLMEngine) ← parse (ToolParser) ← gate (PermissionGate)
              execute (ToolExecutor) → tools (AgentTool) → Workspace/ShellRunner
              checkpoint (GitCheckpointer) · memory (AgentMemory) · persist (SessionStore)
```

- **Isolation**: AgentLoop is an actor; AppState/controllers are MainActor;
  engines are @unchecked Sendable classes with internal locks; MLX work is
  serialized by GenerationGate. Tools are Sendable structs; ToolContext is
  lock-protected.
- **Engine switch**: AppState holds `EngineRouter: LLMEngine`;
  `useRemote(RemoteEndpoint)` / `useLocal()` swap the delegate. The loop and
  UI never know which engine is active.
- **Events**: the loop yields an AsyncStream<AgentEvent> (taskStarted,
  tokenDelta, assistantMessage, toolCallStarted/Finished, awaitingApproval,
  askUser, checkpointCreated/Failed, protocolError, reasoning, planProposed,
  finished); the controller rebuilds the transcript; the stream is finished
  exactly once.
- **Sessions**: SessionRecord (messages, checkpoints, schemaVersion) persisted
  encrypted (AES-GCM, Keychain key cached in memory) with secret redaction;
  restore validates workspace + model; continuation seeds a new loop with
  history and checkpoints.

## 5. Capability inventory

| Capability | Where | Notes |
| --- | --- | --- |
| Local MLX inference | MLXEngine | GenerationGate-serialized Metal; MemoryAdvisor admission; thermal caps |
| BYOK remote engines | RemoteLLMEngine | OpenAI, DeepSeek, LongCat, Alibaba, Gemini, OpenRouter; SSE streaming |
| Tool loop | AgentLoop | one tool call per reply (protocol error otherwise); phase state machine; verification-before-completion gate |
| Permission gate | PermissionGate + CommandPolicy | reads auto; writes/commands approve; safe-command auto-approve |
| Workspace confinement | Workspace | realpath containment, symlink-safe, per-intent resolution |
| Shell execution | ShellRunner | process-group kill, sanitized env (no GIT_*), typed results |
| Git checkpoints/undo | GitCheckpointer + sidebar Undo | index preserved; GC refs; foreign-tree refusal |
| Sessions | SessionStore | encrypted, redacted, restore/continue, recent list |
| Memory | AgentMemory | facts + summaries, modes, keyword-ranked prompt injection |
| Compression | ContextCompactor | 3 levels; pairing preserved |
| Reasoning toggle | PromptBuilder + RemoteLLMClient | think blocks; reasoning_content folded |
| Plan mode | AgentLoop | plan → approve/revise → act |
| Diagnostics | BuildDiagnosticsTool | parsed, breadcrumb UI, post-edit verification (opt-in); failing verification refuses completion |
| Repo context | RepoIndex → PromptBuilder | bounded index + symbol summaries; task-ranked ordering |
| Vision | VisionTool | BYOK describe_image; SmolVLM seam documented |
| Simulator + argent | SimulatorController + sim_* tools | simctl panel + tap/type/describe/screenshot; sim_build_run one-shot loop |
| In-app browser | BrowserController + browser_* tools | agent-driven WKWebView; prompt teaches visual-verify loop |
| Composer | ChatView | attachments, expanding input, flow presets, paste |
| Thermal | ThermalMonitor | kernel + CPU-load proxy |
| CLI | BeetCodeCLI | status/download/generate |

## 6. Key APIs (for extenders)

### LLMEngine (Core/Inference/LLMEngine.swift)
`loadedModelID`, `stats`, `load(directory:modelID:diskBytes:)`,
`unload()`, `reset()`, `stream(adding: [ChatTurn], maxTokens: Int?,
temperature: Double?) -> AsyncThrowingStream<String, Error>`,
`cancelGeneration()`; defaults: `clearCaches()`, `dumpIfResident()`.

### AgentTool (Core/Tools/AgentTool.swift)
`name`, `summary`, `risk: ToolRisk (read/write/execute)`, `schemaText`,
`preview(_ call:in:) -> ApprovalPreview`, `execute(_ call:in: ToolContext)
async throws -> String`. Optionally conform to `CommandExecuting` for typed
command results.

### AgentLoop public surface
`run(userMessage:) -> AsyncStream<AgentEvent>` (rejects concurrent runs),
`resolve(requestID:approved:)`, `answerQuestion(requestID:text:)`,
`resolvePlan(approved:)`, `cancel()`, `sessionRecord`. Configuration:
maxTurns, maxTokensPerTurn, temperature, checkpointingEnabled,
contextWindowTokens, thermalTokenCeiling, verifyAfterEdits, showReasoning,
planMode, memoryMode, compressionLevel.

### ToolExecutor
`execute(_ call:) -> Outcome(output, failed, exitCode?)`; rejects duplicate
tool registration (precondition).

### Workspace
`resolve(_ path:, access: .read/.write/.enumerate) throws -> WorkspacePath`;
`resolvingSymlinks` (realpath-based, /private/var-consistent).

### Persistence
`SessionStore`: save/load(id:)/loadAll/delete/validateWorkspaceBinding/
currentSessionID, redactAndBound. `AppPreferencesStore`: current/save/
validatedWorkspaceURL/bookmarkData. `SettingsStore`: keys below.

## 7. Security model

- **Confinement**: canonical realpath containment; symlinked roots/parents
  rejected or resolved; sibling-prefix safe; per-intent resolution;
  resolved URLs reused between preview and execution.
- **Shell**: safe-command auto-approve only for exact executables with
  in-workspace paths; operators/substitution/redirection/backgrounding and
  outside paths always ask; sanitized environment (GIT_* stripped);
  process-group SIGKILL on timeout/cancel.
- **Checkpoints**: sanitized git env, foreign-tree refusal, index
  preservation, symlink-safe cleanup, GC retention refs.
- **Secrets**: Keychain only (HF token, provider keys, session key),
  in-memory caches, session payload redaction (hf_/ghp_/sk-/Bearer/etc.),
  private file permissions (0700/0600).
- **Approval**: the UI cannot bypass the gate; control tools are loop-
  intercepted; verification builds never run silently.

## 8. Settings reference (SettingsStore keys)

autoApproveEdits, autoApproveCommands, maxTurns, maxTokensPerTurn,
temperature, checkpointingEnabled, verifyAfterEdits, memoryMode,
compressionLevel, composerFlow, showReasoning, planMode.
AppPreferences (JSON): lastWorkspacePath (+bookmark), lastModelID,
lastSessionID, autoResumeDownloads, remoteModel[provider].

## 9. Test strategy

- **FakeLLMEngine**: scripted responses, turn-history recording, held
  streams for deterministic cancellation — AgentLoop tests need no weights.
- **EventCollector**: async event assertions with deadlines.
- **TempWorkspace/GitRepo**: real fs/git fixtures, auto-cleaned.
- **FixtureHub**: local file downloads through the real downloader path
  (HubServing protocol seam).
- **Suites**: AgentLoopTests (20), AgentTests (tools/policy/git/workspace),
  BYOKTests, DiagnosticParserTests, ReasoningTests, MemoryTests,
  PersistenceTests, RepoIndexTests, EndToEndTests (AppState→download→agent),
  SmartDownloaderTests, MemoryAdvisorTests, ToolParserTests, DiffEngineTests.

## 10. Known gaps & improvement candidates

From docs/COMPARISON.md (vs OpenCode/OpenClaude) and the harness audit:

- MCP client support (deferred in v0.2; highest-value ecosystem gap).
- Subagents (task tool with bounded child loops).
- AGENTS.md/CLAUDE.md project-memory convention.
- Hooks (PreToolUse/PostToolUse/Stop) and slash commands.
- Web-fetch tool; side-by-side diff viewer; cost/token tracking; session
  share/export; glob tool; keybind customization; declarative config file.
- Vision: local SmolVLM engine behind VisionProvider once mlx-swift-lm ships
  VLM support (track mlx-swift-examples PR #206).
- Technical debt: `describeImage` uses a semaphore bridge (bounded 15s) —
  could become async when the composer send path is async; SettingsView/
  ModelManagerView carry UI-heavy state that could move to view models.

## 11. Conventions for contributors

1. **Add a tool**: implement AgentTool (schemaText as JSON, risk honest),
   register in AgentSessionController.defaultTools; reads auto-run, writes/
   executes get approval cards; checkpoint-before-mutation is automatic for
   `.write` and mutating commands.
2. **Add a setting**: SettingsStore key + default registration + SettingsView
   section; pass into AgentLoop.Configuration.
3. **Add an engine**: conform to LLMEngine; plug into EngineRouter.
4. **Tests**: deterministic; fake the network (FixtureHub/HubServing) and the
   model (FakeLLMEngine); use TempWorkspace, never real user dirs.
5. **After adding files**: `xcodegen generate` (project.yml is the source of
   truth).
6. **Swift style**: erasable syntax only (no enums-with-associated-value
   issues — plain enums fine), NSLock usage must stay in sync helpers
   (async contexts forbid lock()/unlock()), no literal backticks in
   comments if generated by tooling.

## 12. External integrations

- **argent** (`argent run <tool> --args <json> --json`): sim_* tools;
  banner-tolerant JSON parsing in Summarize.
- **xcrun simctl**: boot/install/launch/screenshot stream.
- **Hugging Face Hub**: downloads with ETag/sidecar resume, Keychain token.
- **Providers**: OpenAI-compatible SSE + Gemini native streaming.

Generated 2026-08-17. Suite: 142 tests green (v0.4: P0 hardening + P1 agent-competitiveness pass).
