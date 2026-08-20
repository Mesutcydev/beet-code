# Open-source parity and product-gap audit

Updated 2026-08-20. This audit compares Beet Code with the current strengths of several open-source coding-agent projects and with the live Claude and Hermes desktop surfaces. It is intentionally capability-oriented: the goal is to identify patterns worth adopting without copying another product's visual language.

## Reference set

| Project | Useful pattern observed | Implication for Beet Code |
| --- | --- | --- |
| [Crush](https://github.com/charmbracelet/crush) | Explicit provider/model configuration, session-oriented work, mid-session model switching, LSP context, and MCP extensibility. | Treat model metadata and session context as durable objects, not transient UI state. |
| [Cline](https://github.com/cline/cline) | One agent surface across IDE, terminal, and headless use; human-in-the-loop approvals; parallel Kanban/worktree workflow. | Keep approvals central, and make a task portable from the macOS UI to a headless or remote session. |
| [Continue](https://github.com/continuedev/continue) | Context is a product surface: codebase questions, docs context, inline edits, autocomplete, and configurable model/provider connections. | Make context attachments and intent presets first-class composer actions rather than hidden prompt behavior. |
| [Aider](https://github.com/Aider-AI/aider) | Repo map, git-native checkpoints, automatic testing/linting, image/web context, voice input, and explicit model tuning. | Build a visible context budget and verification loop around the existing safe edit/checkpoint system. |
| [Claude Squad](https://github.com/smtg-ai/claude-squad) | Multiple agents in isolated workspaces, background execution, review/diff before apply, and resume/pause controls. | The sidebar should become a task/workspace switchboard, not only a chat history. |
| Claude Desktop (live inspection) | Project-first navigation, search, pinned workspaces, local/remote context, model/effort controls, and a quiet input surface. | Keep the composer compact and put durable project context above it. |
| Hermes Desktop (live inspection) | Capabilities, artifacts, scheduled jobs, session filters, tabs, context chip, profile/model controls, and voice actions. | Give the sidebar meaningful modes and expose secondary actions without crowding the send path. |

The historical [OpenCode repository](https://github.com/opencode-ai/opencode) is archived; its README points to [Crush](https://github.com/charmbracelet/crush) as the continuation. Its useful patterns remain relevant, but new implementation comparisons should use Crush rather than treating the archived repository as an active upstream.

## Beet Code status for the 0.8.5 pass

### Working or materially improved

- Local and remote inference share the same permission, tool, checkpoint, hook, and verification loop.
- Gemini model discovery now follows the official paginated model endpoint and filters on `generateContent` capability instead of brittle model-name matching.
- LongCat uses the current OpenAI-compatible endpoint and a real default model ID.
- OpenAI-compatible, Anthropic, and Gemini tool calls use native provider envelopes and are translated back into the shared tool protocol.
- Remote model list errors remain attached to the model-listing surface instead of being mislabeled as failed connection tests.
- Saved models remain selectable even when live discovery is unavailable.
- Per-model capability overrides are keyed by the exact provider/model
  endpoint, including OpenCode and other dynamic gateways; the effective
  context, output, tools, reasoning, vision, and temperature profile is shown
  in Settings and the composer picker.
- Plan mode is passed into prompt construction, reserves reply space, and compacts before the first generation when the prompt is already near the context limit.
- Reasoning is a distinct transcript surface with live progress, instead of being mixed into the final answer stream.
- The composer is intrinsically sized, has a fixed compact editor height, keeps the primary action in a rectangular commit rail, and has a live perimeter trace that responds to focus and hover.
- The composer now preflights persisted conversation history plus the next turn, shows a compact context meter, explains the response reserve/system-prompt caveat, and offers one-click compaction when older tool output can actually be collapsed.
- The sidebar now combines project context, search, chat/imported mode switching, session history, and the existing activity rail. Imported-session actions and tool surfaces remain accessible.
- The chat library now has explicit local/imported headers, source-aware metadata,
  and quieter native-cased project headers instead of a flat repeated history list.
- Task rows persist pins, workspace paths, active phases, and review-needed
  status so the sidebar is a task switchboard rather than only a transcript
  archive.
- Verification is a first-class phase. The native checker detects Xcode
  workspaces/projects, XcodeGen projects, and Swift packages and chooses tests
  when test sources are present.
- Delegated work has explicit research, implement, verify, and review roles;
  child tools and approval behavior are narrowed to the selected role.
- `.beetcode.json` and `.beetcode.jsonc` provide non-secret project policy for
  agent defaults, plan/goal behavior, verification, tool filters, permissions,
  context hints, and answer style; credentials remain in Keychain.
- Provider credentials normalize common copied forms such as `Bearer …` and
  `api_key=…` before testing or saving.
- Context-length rejections now trigger one bounded recovery pass using the
  provider-reported limit, then reset/replay once; the recovery is covered by a
  deterministic AgentLoop test.
- GitHub Actions now regenerates the Xcode project, checks diff hygiene, and
  runs the macOS test suite; bug and provider reports have structured templates.
- Provider contract fixtures now cover LongCat/OpenAI-compatible model discovery, paginated Gemini discovery and capabilities, HTTP error propagation, and OpenAI/Gemini/Anthropic streaming shapes without live credentials.
- Baseline full macOS suite before this slice: 613 tests executed, 1 skipped, 0 failures.
- Remote Beetcode sessions now have Tailscale-first QR pairing, a one-time pairing code, revocable 30-day browser tokens, saved-session continuation on the original session ID, bounded live output, explicit agent phases, and browser approval/question/plan controls. The remote listener never exposes the terminal CLI or the local model API.
- Current post-change verification: the full macOS suite executes 651 tests with 1 skip and 0 failures; the focused agent/provider suite executes 36 tests with 0 failures.

### Remaining product gaps

| Priority | Gap | Why it matters | Suggested next slice |
| --- | --- | --- | --- |
| Done | Per-model capability overrides | Gateways often report incomplete metadata or expose models with nonstandard limits. | Shipped in 0.8.5; exact endpoint identity prevents overrides bleeding between gateways. |
| Done | Task/workspace sidebar | History is not enough for parallel work, background tasks, or isolated workspaces. | Shipped in 0.8.5 with pins, phases, workspace paths, and review-needed state. |
| Done | Specialist/write-capable subagents | Read-only research is useful but cannot parallelize implementation and verification. | Shipped in 0.8.5 with research/implement/verify/review roles and narrowed tool sets. |
| Done | Verification loop | Aider and Cline make testing a visible part of completion. | Shipped in 0.8.5 with detected project checks and a visible verifying phase. |
| Done | Declarative project policy | Settings-only configuration is difficult to share and reproduce. | Shipped in 0.8.5 as `.beetcode.json`/`.jsonc`; credentials stay in Keychain. |
| P2 | Share/import handoff | Local Markdown/JSON export does not cover collaboration or moving a task to another machine. | Define a versioned encrypted task bundle first; consider optional hosted links later. |
| P2 | Background/remote sessions | Remote continuation and reconnectable transcript state now work while the host is running; queued jobs, multiple simultaneous tasks, and resuming after the Mac app quits still need a durable lifecycle. | Add explicit queued/running/paused/awaiting-approval/completed states and a process-independent task runner. |
| P3 | Output styles and shortcut customization | These are quality-of-life features once the task loop is reliable. | Add concise/normal/verbose answer styles and editable send/stop/plan shortcuts. |

## Design conclusions for the hybrid surfaces

The strongest shared pattern is separation of concerns:

1. The sidebar owns durable context: workspace, task/session identity, search, filters, imported work, and secondary tools.
2. The composer owns the next action: prompt, context attachments, intent, plan/reasoning state, model, and send/stop.
3. The transcript owns execution state: reasoning, approvals, tool results, diffs, verification, and final output.

That division is now reflected in the implementation. Further polish should make state more legible rather than adding more pills or decorative controls. The composer border should remain a state signal: calm trace at rest, brighter trace on focus, and a distinct running/stop treatment while work is active. Reduced-motion settings must continue to disable the moving trace.

## Recommended next order

1. Define a versioned task bundle and a safe import flow that can rebind a task
   to a user-selected workspace.
2. Add an explicit durable queue for remote/background tasks while keeping one
   active model run per local session.
3. Add concise/normal/detailed output style enforcement and editable shortcuts.

This keeps the next work focused on reliability and task completion while preserving the new premium, compact visual direction.
