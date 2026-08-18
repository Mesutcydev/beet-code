# Beet Code — Competitive Analysis & Roadmap

Generated 2026-08-18 from three research passes (LM Studio/Bionic/Ollama,
OpenCode/ZCode, Hermes/OpenClaude). Full source reports:
`~/.hermes-cache/beetcode-research/beetcode-competitive-analysis.md`,
`~/beetcode-competitive-research/hermes-openclaude-structural-analysis.md`.

## Headline

**"Bionic" is LM Studio's own agentic app** (v1.0.0 shipped 2026-07-17,
weekly releases since). It is the direct benchmark — but it has three holes
Beet Code already fills: **no BYOK** (their cloud is credit-only), **no
context compression**, **no persistent memory**. Beet Code's wedge:
*local-first, your keys, real memory.*

## Matrix (verified today, not claimed)

| Capability | Beet Code | Bionic/LM Studio | OpenCode | ZCode | Hermes |
| --- | --- | --- | --- | --- | --- |
| Native MLX local inference | ✅ | ✅ (mlx-engine) | ⚠️ via Ollama | ⚠️ via local providers | ❌ |
| BYOK remote providers | ✅ 7 + Test buttons | ❌ credit cloud | ✅ 75+ | ✅ + coding plans | ✅ |
| Agentic tool loop + approvals | ✅ diff-preview cards | ⚠️ chat-directed | ✅ glob rules | ✅ 4 modes | ✅ approval modes |
| Plan mode | ✅ | ⚠️ | ✅ plan agent | ✅ goal mode | ✅ |
| Git checkpoints / undo | ✅ index-preserving | ⚠️ | ✅ snapshots | ✅ per-file reset | ✅ |
| Context compression | ✅ 3 levels | ❌ | ✅ configurable | ✅ auto (~34k early) | ✅ dual-threshold |
| Memory | ✅ facts+summaries | ❌ | ❌ | ✅ MEMORY.md | ✅ bounded files |
| Encrypted sessions | ✅ AES-GCM | ❌ | ❌ | ❌ | ❌ |
| Local API server | ✅ :loopback OpenAI-compat (app + `lf serve`) | ✅ :1234 OpenAI+Anthropic | ✅ serve mode | ❌ | ✅ proxy |
| MCP | ✅ stdio JSON-RPC + registry | ✅ via API | ✅ +OAuth | ✅ +importers | ✅ |
| AGENTS.md/CLAUDE.md convention | ✅ workspace + global → system prompt | ❌ | ✅ /init | ✅ global+project | ✅ |
| Hooks | ✅ subprocess JSON (PreToolUse/PostToolUse/Stop) | ❌ | ✅ JS plugins | ✅ subprocess JSON | ✅ |
| Declarative config file | ❌ UI only | ⚠️ | ✅ opencode.json | ⚠️ | ✅ config.yaml |
| Subagents | ❌ | ⚠️ | ✅ md agents | ✅ beta | ✅ |
| Thermal/RAM admission | ✅ unique | ❌ | ❌ | ❌ | ❌ |
| iOS Simulator + argent tools | ✅ unique | ❌ | ❌ | ❌ | ❌ |

## What to build, in order (against your goal list)

### Tier 1 — the two missing pillars of your stated goals
1. ~~**Local API server**~~ ✅ **DONE (v0.3)**: `Core/Server/LocalAPIServer`
   (zero-dep POSIX sockets, loopback-only) + `OpenAIRoutes`
   (`/v1/models`, `/v1/chat/completions` streaming + non-streaming,
   `/health`). Stateless contract: engine reset + full replay per request.
   Settings card in the app; `lf serve [--port N] [--model <id>]` runs it
   headless. 10 e2e tests + live curl smoke test. Also: bearer-token auth,
   Anthropic-format `/v1/messages`, idle-TTL unload (all with e2e tests).
2. **MCP client** ✅ **DONE**: `Core/MCP/MCPClient.swift` (stdio JSON-RPC
   2.0, newline-delimited, id-matched, bounded timeouts) + registry
   (`MCPRegistry`) + config at `~/.beetcode/mcp.json` /
   `<workspace>/.beetcode/mcp.json`.

### Tier 2 — compatibility conventions (cheap, high leverage)
3. **AGENTS.md/CLAUDE.md** ✅ **DONE**: `ProjectInstructions` loads
   `AGENTS.md` / `CLAUDE.md` (workspace + global) into the system prompt,
   bounded (8K), with tests.
4. **Hooks** ✅ **DONE**: `Core/Agent/HookRunner.swift` — ZCode-style
   **subprocess JSON** (stdin JSON → stdout JSON/exit code). Events:
   `PreToolUse` (deny/rewrite), `PostToolUse` (observe),
   `Stop` (reason). Hook crash/timeout is fail-open — only explicit `deny`
   blocks a tool. Hooks cannot bypass the PermissionGate.
5. **Slash commands** ✅ **DONE**: `/plan /undo /compact /model /memory`
   — parser in `SlashCommand.swift`, execution in the controller.

### Tier 3 — differentiation deepeners
6. **Declarative permission rules** (OpenCode-style): per-tool
   allow/ask/deny with glob rules on arguments, stored in a
   `beetcode.json` project file → also delivers your "fully customizable"
   goal (config file beats UI-only settings).
7. **Session fork/export/import** (+ import from OpenCode/Claude Code JSON —
   the user-poaching feature ZCode ships).
8. **Markdown-defined agents/subagents**: bounded child `AgentLoop`s with
   their own prompt/model/permissions (Hermes pattern: summary-only return).
9. **Per-agent model routing** (OpenClaude idea): cheap local MLX for
   explore/search turns, BYOK frontier for edits — a real cost moat.
10. **Tool-schema sanitizer** (OpenClaude lesson): MLX/open models break on
    recursive JSON schemas; sanitize before every generation.

### Explicitly NOT worth copying
- ZCode's bots/Feishu/WeChat channels, repo-wiki, browser automation
  (wrong product shape for a local-first Mac tool).
- LM Studio's credit cloud (contradicts BYOK wedge).
- OpenCode's MDM config (no enterprise fleet need yet).

## Positioning sentence

> BeetCode is the only Apple-Silicon coding agent that runs open models
> locally via MLX with real thermal/RAM discipline, keeps BYOK keys on your
> machine, encrypts your history, remembers your projects, and hooks into
> your workflow — while speaking OpenAI-compatible API and MCP so it plugs
> into everything else.
