# Beet Code v0.2 — Acceptance Flow

This is the manual acceptance pass for the v0.2 safety/durability/diagnostics
work. Each step names the behavior under test and where it lives. Run the
suite first — the automated harness covers the same ground headlessly:

```sh
cd BeetCode
xcodegen generate
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' -derivedDataPath .derived test
```

Expected: all tests green, no model weights downloaded, no Metal touched
(AgentLoop/EndToEnd suites drive FakeLLMEngine and local fixture downloads).

## 1. Workspace confinement

- Open a folder with a symlink inside pointing OUTSIDE it; ask the agent to
  read a file through the symlink → refused with “outside the open workspace”.
  Same for writing a new file beneath the symlink.
- Open a folder whose name is a prefix of another folder next to it
  (e.g. `proj` next to `proj-other`); the agent must never touch
  `proj-other`. Path-component containment is enforced on canonical
  (realpath) paths.
- Open a folder and read a file via `..` traversal, an absolute path outside,
  `~/…`, and a normalized `a/../b` path → only the inside ones succeed.

## 2. Command policy

- With “Auto-approve safe commands” OFF (default): every `run_command` shows
  an approval card, including `swift build`.
- Turn safe auto-approve ON: `swift build`, `ls`, `git status`, `rg pattern`
  run without approval; `ls; rm -rf ~`, `echo $(whoami)`, `cat /etc/passwd`,
  `ls ..`, `git status /etc`, `sleep 5 &` all still require approval.
- Run a command with an ambient `GIT_DIR` exported in the terminal that
  launched the app: git commands the agent runs still operate on the
  workspace, never the ambient repo.
- Start a long command (e.g. `sleep 60`) and press Stop: the shell and its
  children die immediately (process-group kill) — `pgrep sleep` shows
  nothing.

## 3. Checkpoints and undo

- In a git workspace, approve a file edit: a checkpoint row appears in the
  transcript BEFORE the mutation runs.
- Create a new file after the checkpoint, then hit **Undo** in the sidebar:
  the edit is reverted AND the file created after the checkpoint is removed.
- Stage a change in git before running the agent; after Undo the worktree is
  restored while your staged change is still staged (`git status` shows `M`
  in the index column).
- In a NON-git workspace, approve an edit: the mutation is refused with a
  “checkpoint failed” notice — nothing changes on disk.
- A filename containing a newline survives snapshot and restore.

## 4. Relaunch durability

- Open a workspace, run a task, quit, relaunch: the workspace and session
  transcript come back (sidebar → Recent Sessions is also clickable).
- Start a model download, Pause, quit, relaunch: the row shows **Paused**
  with the byte count; Resume continues from the sidecar offset. With
  “Auto-resume interrupted downloads” enabled in Settings, relaunch resumes
  automatically.
- Remove the model folder from disk while the app is closed; relaunch: the
  stale registry entry is repaired (model no longer listed as installed),
  and the workspace/session restore falls back safely.
- Quit mid-download and inspect `~/Library/Application Support/BeetCode/`
  — session payloads are encrypted (Keychain key) and the directories are
  private (0700/0600).

## 5. Model lifecycle

- Load model A, then load model B: with EnginePool both can stay resident
  (up to 4, LRU eviction). RAM is admitted by MemoryAdvisor, not "never
  both".
- Unload/Remove clears the active-model badge; relaunch auto-reloads the
  last chat model when it is still installed.
- During critical thermal state the agent stops and generation is cancelled;
  on severe memory pressure the largest idle resident is dumped first.

## 6. Build diagnostics

- Introduce a compile error (via an approved edit) in a Swift workspace; ask
  the agent to run `build_diagnostics` (or enable “Verify edits with a
  build” in Settings): the transcript shows diagnostics grouped by file with
  error/warning coloring, line:column, and the raw output one click away.
  The agent receives the normalized diagnostics and can repair the edit.
- A command that is not policy-safe still shows an approval card before the
  build runs; declining it produces a notice, never a silent execution.

## 7. Repository context

- Open a repository with `node_modules`, `.build`, or a `.gitignore`; the
  system prompt's workspace index excludes those, lists source files with
  one-line symbol summaries, and stays bounded (~400 files) even in
  pathological repositories.

## Deferred (explicitly out of v0.2)

- MCP client support
- GGUF/llama.cpp backend
- OpenAI-compatible server
- Multiple resident models
- Parallel chunk downloads
- Concurrent subagents
# Beet Code v0.3 — Acceptance additions

## BYOK providers

- Settings → BYOK Providers: add a key for OpenAI, DeepSeek, LongCat, Alibaba
  (DashScope), Gemini, or OpenRouter; pick a model (preset or custom). Keys
  live in the Keychain (verify with `security find-generic-password -s
  com.beetcode.provider.openai`).
- Model Manager → Remote (BYOK): activate a configured provider; the status
  bar shows `Provider · model`; the agent runs against the remote model,
  with the same tools, approvals, checkpoints, and memory.
- Switch back to local: Model Manager → Use local, then load a downloaded
  model.

## iOS Simulator panel + argent

- Toolbar → Simulator: the panel docks beside the chat (not a modal). Close
  it with the ✕ in the panel header or the toolbar toggle.
- Boot a device (iPhone 17 Pro, iOS 26.5/27.0 runtimes), install an .app
  (file picker + optional bundle id), launch, watch the live screen stream.
- With argent installed (`which argent`), ask the agent to interact:
  `sim_list_devices` → `sim_boot_device` → `sim_launch_app` →
  `sim_describe` to read the accessibility tree → `sim_tap` / `sim_type`
  to drive the app. Interactions show an approval card first.
- `sim_screenshot` saves PNGs under `.beetcode/screenshots/` in the
  workspace; the agent can then `describe_image` them with a vision
  provider.

## Memory & compression

- Settings → Memory & Context: try mode Facts, run two different sessions in
  the same workspace, then start a third mentioning the same topic — the
  relevant fact appears in the agent's system prompt (check the transcript
  header or ask the agent what it remembers).
- `memory_add` / `memory_delete` tools appear in the prompt when memory is
  on; the agent uses them to maintain facts.
- Compression: set Aggressive and run a long task — old tool outputs become
  stubs and preserved outputs are truncated, while assistant/tool pairing
  stays intact.

## Reasoning & thermal

- Enable “Show model reasoning”: Qwen3-style `<think>` blocks appear as a
  collapsible Reasoning card (local and remote models; DeepSeek reasoner's
  `reasoning_content` is folded in).
- Thermal: run a heavy build with the status bar visible — sustained CPU now
  escalates the chip from Cool → Warm → Hot even when the kernel thermal
  state stays nominal. Throttling caps kick in accordingly.

## Vision

- With OpenAI/Gemini/OpenRouter configured, `describe_image` (agent tool)
  describes workspace images. Local SmolVLM arrives behind the same tool
  once mlx-swift-lm ships VLM support.