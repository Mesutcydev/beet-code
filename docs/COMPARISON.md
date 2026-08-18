# Beet Code vs OpenCode & OpenClaude — Feature Gap Analysis

Compared against **OpenCode** (opencode-ai/opencode — terminal agent with TUI,
plugins, LSP, sessions/share) and **OpenClaude** (0xysh/openclaude — an
OpenAI-compatible shim that exposes the full Claude Code toolchain — CLAUDE.md,
hooks, subagents, permission modes, MCP — to any LLM).

## Coverage matrix

| Capability | BeetCode | OpenCode | OpenClaude (Claude Code surface) |
| --- | --- | --- | --- |
| Local model inference (MLX) | ✅ native | ⚠️ via Ollama | ⚠️ via Ollama |
| BYOK remote providers | ✅ 6 providers | ✅ many | ✅ 200+ (shim) |
| Tool loop + permission gate | ✅ approval cards | ✅ allow/ask/deny rules | ✅ permission modes |
| Safe-command policy | ✅ | ✅ | ✅ (Bash tool rules) |
| Git checkpoints / undo | ✅ | ✅ | ✅ |
| Sessions persist/resume | ✅ encrypted | ✅ | ✅ |
| Session share | ❌ | ✅ | ✅ /share |
| Plan mode (plan → approve → act) | ❌ | ✅ | ✅ |
| MCP client | ❌ (deferred) | ✅ | ✅ |
| Subagents | ❌ (deferred) | ✅ task tool | ✅ |
| CLAUDE.md / AGENTS.md memory file | ❌ (facts-only memory) | ⚠️ rules | ✅ |
| Hooks (PreToolUse/PostToolUse/Stop) | ❌ | ✅ plugins | ✅ |
| Slash / custom commands | ❌ | ✅ | ✅ |
| Web fetch tool | ❌ | ✅ | ✅ |
| Attachments (images/files into prompt) | ❌ (describe_image only) | ❌ | ✅ |
| LSP integration | ❌ (build diagnostics only) | ✅ | ✅ IDE |
| Dedicated diff viewer | ⚠️ unified text only | ✅ side-by-side pane | ✅ |
| Glob tool | ❌ (list+search only) | ✅ | ✅ |
| Token/cost tracking | ❌ (tok/s only) | ✅ | ✅ /cost |
| Output styles (concise/verbose) | ❌ | ❌ | ✅ |
| Keybind customization | ❌ | ✅ | ✅ |
| Declarative config file | ❌ (Settings UI only) | ✅ opencode.json | ✅ settings.json |
| Long-running dev servers | ❌ (kills on timeout) | ✅ | ⚠️ |
| Memory (facts/summaries, options) | ✅ | ❌ | ✅ CLAUDE.md |
| Reasoning toggle | ✅ | ✅ | ✅ |
| Build diagnostics + breadcrumbs | ✅ | ✅ LSP | ✅ |
| Thermal/power management | ✅ | ❌ | ❌ |
| iOS Simulator + argent tools | ✅ unique | ❌ | ❌ |
| Vision tool (BYOK) | ✅ | ⚠️ | ✅ |
| Encrypted session storage | ✅ | ❌ | ❌ |

## Missing features, prioritized

### High value
1. **Plan mode** — explicit plan → user approves → agent acts phase. The
   single most-requested workflow both competitors share. Needs an
   AgentLoop phase flag + a plan card in the transcript.
2. **MCP client support** — stdio + SSE servers; tools discovered at runtime
   and registered with the permission gate (MCP tools = execute risk by
   default). Ecosystem win; was deferred in v0.2.
3. **Subagents** — model-defined subagents (like Claude Code) or a task tool
   that spawns bounded child loops with their own prompts; results return as
   observations. Deferred in v0.2 — now the main remaining orchestration gap.
4. **CLAUDE.md / AGENTS.md convention** — auto-load the workspace's memory
   file into the system prompt (with the existing memory modes layered on
   top). Cheap and very high compatibility value.
5. **Attachments** — drag/drop or paste images/files into the composer;
   images go to vision-capable providers, files get read+quoted. Bridges the
   gap between describe_image and real multimodal workflows.

### Medium value
6. **Hooks** — user-configured shell commands on PreToolUse / PostToolUse /
   Stop / Notification events (JSON stdin, JSON stdout contract).
7. **Slash commands** — /plan, /resume, /undo, /compact, /model, /memory,
   plus user-defined commands stored per workspace.
8. **Web fetch tool** — fetch a URL (bounded, approval-gated) so the agent
   can read docs; pair with search.
9. **Side-by-side diff viewer** — expandable per-edit diff pane in the
   transcript instead of unified text only.
10. **Cost/token tracking** — per-session counters from remote engines
    (usage deltas in OpenAI/Gemini chunks) shown in the status bar and
    session list.
11. **Session share/export** — export a session as Markdown/JSON (no cloud);
    optional encrypted link is a later step.
12. **Glob tool** — dedicated glob file discovery (fast, bounded) alongside
    list_directory/search.

### Lower value / polish
13. **Keybind customization** — configurable shortcuts for send/stop/undo.
14. **Declarative config file** — opencode.json-style overrides: model
    defaults, permission allow/ask/deny rules, composer flow, theme.
15. **Output styles** — concise/verbose presets applied to the system prompt.
16. **Long-running dev servers** — a managed background-process tool that
    keeps a server alive across turns and reattaches to its output.
17. **App themes** — light/dark/contrast presets beyond composer flows.

## Where BeetCode is ahead

- Local-first MLX inference with real thermal/RAM management (unique).
- Approval cards with diff previews + safe-command policy (stronger default
  posture than either competitor).
- Checkpoints that preserve the user's git index state.
- Encrypted sessions with secret redaction (neither competitor encrypts).
- Built-in iOS Simulator panel + argent device tools (unique).
- Bounded repo index with per-file symbol summaries.

## Suggested order of implementation

1. Plan mode (loop phase + UI card) — smallest, highest value.
2. AGENTS.md / CLAUDE.md convention — one prompt-builder change.
3. Attachments (composer) + image → vision providers.
4. MCP client (stdio first).
5. Subagents (task tool with bounded child loops).
6. Slash commands + hooks.
7. Cost tracking, diff viewer, session export, glob tool.