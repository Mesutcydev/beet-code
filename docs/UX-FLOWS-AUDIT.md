# Beet Code — UX Audit: Task Flows

Generated 2026-08-18 by direct code reading (App/, Core/) — written in-house
after repeated subagent API-timeout failures. Every flow below was traced
through the actual code paths.

## Flow findings

| # | Flow | Friction found | Fix |
| --- | --- | --- | --- |
| 1 | First launch → workspace → model → first task | Empty state is descriptive but has **no actionable buttons** ("open Model Manager ⌘M" is text only). Three separate gestures needed (open folder, ⇧⌘M, pick model) with no guided path. | Add CTA buttons to `emptyState`: "Open Project Folder…" + "Model Manager (⇧⌘M)". One-screen onboarding checklist (LM Studio pattern). |
| 2 | Download → resume → load | Solid: sidecar resume survives quit; paused rows show byte counts. Minor: "Retry" appears on `.failed` with no detail expansion. | Surface failure reason inline (the `.failed(message)` already carries it — render fully, not 2-line-clipped). |
| 3 | Import local model | `NSOpenPanel` + `copyItem` run **on the MainActor** — importing a multi-GB folder freezes the UI. No progress feedback. | Move copy to `Task.detached` with a progress state in the sheet; or reference-in-place when the folder is already inside Models. |
| 4 | BYOK key → test → activate | Key is saved in **Settings**, activation happens in **Model Manager** — two windows, no cross-link. After saving a key the user gets no "now activate it" nudge. Terminology split: Save/Test here vs "Use remote" there. | Add a "Use remote" shortcut button on each configured provider card; unify verb to "Activate". |
| 5 | Approval flow | **Dead end:** declining ANY tool call ends the whole run (`finish(.declined)`) — the agent can't try an alternative. OpenCode rejects-and-continues. | Feed "declined by user" as an observation and keep the loop running (the code path already builds the observation at `AgentLoop.swift:411-414`, then returns — change `finish` to `continue`). |
| 6 | Plan mode | Works: propose → approve/revise/cancel. Revision feedback correctly re-plans. No issue found. | — |
| 7 | Checkpoint + Undo | Works: checkpoint precedes mutation; Undo restores. Non-git workspace correctly refuses. | — |
| 8 | Session restore | Works: recent sessions clickable, workspace re-pointed. No explicit "continue last session?" prompt on launch (silent restore is fine, but title duplication confused users — fixed this session with msg-count + timestamps). | — |
| 9 | Error recovery | Load-failed now dismissible. Composer placeholder now says **"Load a model to begin…"** when a workspace is open but no model is loaded — no more misleading "Open a workspace" ghost. Bad key/model still surface the real provider error via Test. | — |
| 10 | Simulator panel | Docks correctly. If `argent` is missing, sim_* tools fail with an unhelpful tool error; no install guidance in the panel. | Panel header hint when `which argent` fails: "Install argent for device tools". |

## Terminology inconsistencies

- **Load** (Model Manager) vs **Use remote** (BYOK) vs **Activate** (code) — pick "Load" for local, "Activate" for remote, apply everywhere.
- **Composer style** (Settings) vs **flow** (code, `ComposerFlow`) — rename code-facing docs; UI already consistent.
- **Plan** toggle (accessory) vs **Plan mode** (Settings agent tab) — same setting, two surfaces; fine, but Settings row should say it's the same switch.

## Onboarding gaps

- No first-run checklist (workspace ✓ model ✓ key ✓).
- Lattice/Plan/Reasoning buttons have tooltips only — a one-time coach mark
  on first expansion would help.
- AGENTS.md convention not read (competitive gap, see COMPETITIVE-ANALYSIS.md).
