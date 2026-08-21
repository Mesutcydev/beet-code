# Beet Code competitive comparison

Updated 2026-08-21. This comparison uses the current product documentation for
the mainstream agentic coding tools that most directly overlap Beet Code:
[Codex](https://developers.openai.com/codex/use-cases),
[Cursor](https://docs.cursor.com/chat/overview),
[Claude Code](https://docs.anthropic.com/en/docs/claude-code/cli-usage),
[GitHub Copilot](https://docs.github.com/en/copilot/reference/customization-cheat-sheet),
and [Windsurf](https://docs.windsurf.com/windsurf/cascade/memories).

The goal is not visual imitation. Beet Code should take the interaction
patterns that improve completion, control, and review, while remaining a
native Apple-silicon product.

## What the leaders get right

| Product | Strongest useful pattern | Beet Code response |
| --- | --- | --- |
| Codex | Goal-oriented work that understands a codebase, builds, tests, reviews, and can preserve durable workflows. | Goal mode, project instructions, skills/commands, verification phase, and an Apple-app delivery template. |
| Cursor | Clear Agent/Ask-style modes, parallel chat surfaces, automatic checkpoints, integrated diff review, and a compact grouped activity log. | Auto/Goal plus specialist profiles, task switchboard, git checkpoints, split/unified diff, and a single collapsible agent activity surface. |
| Claude Code | Explicit plan and permission modes, resumable sessions, MCP, configurable tools, and automation-friendly structured output. | Plan approval, per-tool risk gates, encrypted resume, MCP, task bundles, remote queue, and CLI/app-server compatibility. |
| GitHub Copilot | A composable customization model: instructions, custom agents, subagents, skills, hooks, and MCP. | AGENTS/CLAUDE/Cursor/Copilot instruction discovery, specialist subagents, foreign skill discovery, hooks, and MCP. |
| Windsurf | Durable memories and scoped rules, plus reusable multi-step workflows. | Workspace memory, project policy, intent presets, slash commands, and reusable Apple delivery prompts. |

## Capability matrix

| Capability | Beet Code | Codex | Cursor | Claude Code | Copilot | Windsurf |
| --- | --- | --- | --- | --- | --- | --- |
| Autonomous multi-file edits and commands | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plan-before-edit workflow | ✅ | ✅ | ✅ mode | ✅ | ✅ custom agent | ✅ |
| Reviewable diffs and rollback | ✅ file/hunk review + checkpoint | ✅ | ✅ | ✅ git | ✅ PR review | ✅ checkpoint |
| Project instructions / rules | ✅ broad compatibility | ✅ | ✅ | ✅ | ✅ | ✅ |
| MCP and reusable skills/workflows | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Specialist write-capable subagents | ✅ isolated worktrees | ✅ | ⚠️ parallel agents | ✅ | ✅ | ⚠️ workflows |
| Background or remote continuation | ✅ local queue + remote browser | ✅ | ✅ cloud | ✅ remote surfaces | ✅ cloud agent | ✅ |
| Local on-device models | ✅ MLX + GGUF | ❌ | ⚠️ external runtime | ⚠️ external gateway | ⚠️ external runtime | ⚠️ external runtime |
| Native iOS Simulator control | ✅ | ⚠️ shell/Xcode | ❌ | ⚠️ shell | ⚠️ IDE tools | ❌ |
| Native macOS UI inspection/control | ✅ | ✅ computer use | ❌ | ⚠️ | ❌ | ❌ |
| Thermal and memory governance | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Encrypted local session storage | ✅ | implementation-specific | ❌ | ❌ | cloud-managed | ❌ |

## Product decisions from this pass

1. **Activity, not raw chain-of-thought.** Reasoning and tool plumbing now
   collapse into one quiet work log. Final answers keep the strongest visual
   hierarchy; detailed reasoning remains available on demand.
2. **Live progress stays lightweight.** Streaming reasoning is a short status
   row with the latest useful excerpt, not a large monospace card that reflows
   continuously.
3. **Reasoning visibility is a display preference.** It moved out of the
   per-turn command rail and into the composer menu, leaving Plan as the only
   true execution toggle.
4. **Apple delivery is discoverable.** The composer menu can prepare a full
   Research → Build → Review → Verify goal for either iPhone/iPad or macOS.
   The existing native tools then scaffold, build, launch, inspect, fix, and
   verify the app.
5. **Apple silicon remains a product boundary.** The app and generated macOS
   projects target `arm64`, exclude `x86_64`, and use native SwiftUI/MLX paths.
6. **Completion is an outcome, not another chat bubble.** Finished tasks now
   summarize actions, changed files, checks, and release artifacts. Ship
   results expose the package and report directly instead of burying paths in
   command output.
7. **Change review is native and reversible.** A changed-files workspace
   supports split or unified review, hunk-level accept/reject, staged-state
   warnings, and a restore checkpoint created before the first rejection.
8. **Implementation specialists are isolated.** Write-capable nested agents
   start from the exact dirty tree in a linked worktree, then merge one checked
   patch back into the visible workspace. Failed merges retain the worktree for
   recovery.
9. **Apple delivery produces a handoff artifact.** Ship Center verifies,
   archives, packages, hashes, and writes a readable Ship Report. It defaults
   to unsigned output; developer signing and iOS export are explicit opt-ins.
   A native setup sheet selects valid Keychain identities and connected
   physical devices, then Xcode signs and `devicectl` installs without exposing
   certificate passwords or private keys to the agent.
10. **Coding-tool setup is portable.** Current and legacy Cursor chats import
    locally. Claude Code, Codex, Cursor, Copilot, Windsurf, OpenCode, and Agent
    Skills resources are normalized into composer slash commands, including
    declarative skills found inside plugin bundles. Any other IDE can be added
    by connecting its resource folder; executable plugin setup stays inert.

## Next high-value work

1. A concurrent scheduler that can run multiple isolated specialist agents and
   present their progress as one task without workspace races.
2. Optional App Store Connect upload, notarization, and TestFlight handoff on
   top of Ship Center's local signed archive, IPA export, and device install.
3. Optional GitHub issue/PR handoff, without weakening the local-first path.
4. Symbol-aware code navigation and references inside changed-file review.
5. Hosted task links only after expiry, encryption, deletion, and retention
   semantics are designed explicitly.
