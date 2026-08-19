# Beet Code vs OpenCode & OpenClaude — Feature Gap Analysis

Compared against **OpenCode** (opencode-ai/opencode — terminal agent with TUI,
plugins, LSP, sessions/share) and **OpenClaude** (0xysh/openclaude — an
OpenAI-compatible shim that exposes the full Claude Code toolchain — CLAUDE.md,
hooks, subagents, permission modes, MCP — to any LLM).

Updated 2026-08-19 against the current tree (v0.8 + computer use). Older
rows that claimed Plan / MCP / hooks / slash / AGENTS.md / attachments were
missing are **stale** — those shipped.

## Coverage matrix

| Capability | BeetCode | OpenCode | OpenClaude (Claude Code surface) |
| --- | --- | --- | --- |
| Local model inference (MLX + GGUF) | ✅ native | ⚠️ via Ollama | ⚠️ via Ollama |
| BYOK remote providers | ✅ 8+ (OpenAI/DeepSeek/LongCat/Alibaba/Gemini/OpenRouter/Anthropic/Custom) | ✅ many | ✅ 200+ (shim) |
| Tool loop + permission gate | ✅ approval cards | ✅ allow/ask/deny rules | ✅ permission modes |
| Safe-command policy | ✅ | ✅ | ✅ (Bash tool rules) |
| Git checkpoints / undo | ✅ | ✅ | ✅ |
| Sessions persist/resume | ✅ encrypted | ✅ | ✅ |
| Session export | ✅ Markdown/JSON (local) | ✅ | ✅ /share |
| Session share (cloud link) | ❌ | ✅ | ✅ /share |
| Plan mode (plan → approve → act) | ✅ | ✅ | ✅ |
| MCP client | ✅ stdio + HTTP | ✅ | ✅ |
| Subagents | ✅ read-only `task` (8 turns) | ✅ task tool | ✅ |
| CLAUDE.md / AGENTS.md memory file | ✅ (+ Cursor/Copilot conventions) | ⚠️ rules | ✅ |
| Hooks (PreToolUse/PostToolUse/Stop) | ✅ | ✅ plugins | ✅ |
| Slash / custom commands | ✅ (+ discovered foreign skills) | ✅ | ✅ |
| Web fetch tool | ✅ approval-gated, bounded | ✅ | ✅ |
| Attachments (images/files into prompt) | ✅ | ❌ | ✅ |
| LSP integration | ⚠️ intelligence layer + build diagnostics | ✅ | ✅ IDE |
| Dedicated diff viewer | ✅ split + unified | ✅ side-by-side pane | ✅ |
| Long-running dev servers | ✅ background_process | ✅ | ⚠️ |
| Glob tool | ✅ `glob` + `find_files` | ✅ | ✅ |
| Token/cost tracking | ✅ session chip (estimate) | ✅ | ✅ /cost |
| Output styles (concise/verbose) | ❌ | ❌ | ✅ |
| Keybind customization | ✅ Enter-sends + ⌘N / ⌘. / ⇧⌘M | ✅ | ✅ |
| Declarative config file | ❌ (Settings UI only) | ✅ opencode.json | ✅ settings.json |
| Memory (facts/summaries, options) | ✅ | ❌ | ✅ CLAUDE.md |
| Reasoning toggle | ✅ | ✅ | ✅ |
| Build diagnostics + breadcrumbs | ✅ | ✅ LSP | ✅ |
| Thermal/power management | ✅ | ❌ | ❌ |
| iOS Simulator + argent tools | ✅ unique | ❌ | ❌ |
| In-app agent browser | ✅ | ⚠️ | ✅ |
| Computer use (drive any Mac app) | ✅ AX tree + CGEvent | ❌ | ⚠️ |
| Vision tool (BYOK + local VLM) | ✅ | ⚠️ | ✅ |
| Encrypted session storage | ✅ | ❌ | ❌ |

## Missing features, prioritized

### High value
1. **Write-capable / specialist subagents** — today's `task` is read-only
   research. A child that can edit (with the same approval gate) is the
   remaining orchestration gap.
2. **Side-by-side diff viewer** — expandable per-edit diff pane in the
   transcript instead of unified text only.

### Medium value
3. **Session share** — optional encrypted link on top of local Markdown/JSON
   export.
4. **Long-running dev servers** — a managed background-process tool that
   keeps a server alive across turns and reattaches to its output.

### Lower value / polish
5. **Keybind customization** — configurable shortcuts for send/stop/undo.
6. **Declarative config file** — opencode.json-style overrides: model
   defaults, permission allow/ask/deny rules, composer flow, theme.
7. **Output styles** — concise/verbose presets applied to the system prompt.

## Where BeetCode is ahead

- Local-first MLX + GGUF inference with real thermal/RAM management (unique).
- Approval cards with diff previews + safe-command policy (stronger default
  posture than either competitor).
- Checkpoints that preserve the user's git index state.
- Encrypted sessions with secret redaction (neither competitor encrypts).
- Built-in iOS Simulator panel + argent device tools (unique).
- Agent-controlled in-app browser + computer-use (AX tree + screenshots +
  CGEvent input), with observe → act → re-observe guidance in the prompt.
- Bounded repo index with per-file symbol summaries + workspace intelligence.

## Suggested order of implementation

1. Write-capable / specialist subagents.
2. Side-by-side diff viewer.
3. Long-running dev servers.
4. Declarative config + keybind customization.
