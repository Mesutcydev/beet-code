# Composer Design — Audit & Hybrid Master (v0.4)

> **Updated for the Intent redesign (2026-08-18).** The Intent Lattice grid is
> gone. The composer below is the app's single input surface; the per-turn
> agent direction lives in the Intent picker (see "Intent" section at the end).

## Audit of leading composers

| App | Input style | Attachments | Expansion | Context & actions |
| --- | --- | --- | --- | --- |
| Cursor | Full-width bottom bar, rounded, thin border + shadow | Paperclip; @-mention files; context chips (files/symbols) | Auto-grows to ~200px then scrolls | Model picker right; send appears with text; stop while running; agent mode toggle |
| ChatGPT | Rounded-2xl bar, centered column | Paperclip + camera; tools row (search/think/vision) as chips | Auto-grows; char counter near limit | Submit morphs to stop; web-search chip; suggestions above |
| Claude | Minimal rounded bar | Paperclip; plan-mode toggle | Grows | Model + style pickers; arrow send |
| GitHub Copilot | Dockable panel input | Context chips (files, selections) | Grows | Preview toggle; slash commands |
| Linear / Warp | Keyboard-first, minimal | None | Grows | Cmd+Enter to send; focus-first |

## What each does best (the hybrid picks)

1. **Cursor**: full-width expanding textarea with a real focus ring, context
   chips, contextual send/stop, model picker. The strongest 'work surface'
   pattern.
2. **ChatGPT**: tool/attachment chips that are *visible affordances* (not
   hidden), submit↔stop morphing, auto-grow with a sensible max.
3. **Claude**: plan-mode as a first-class toggle next to the input — perfect
   for our plan mode.
4. **Linear/Warp**: keyboard discipline — Enter sends, Shift+Enter newline,
   Esc stops, ⌘V pastes images.

## Hybrid Master Composer (implemented)

Layout (bottom-up):

```
┌────────────────────────────────────────────────────────┐
│ [Build ✕] [@git ✕]                            Clear     │ ← intent chips (only when set)
│ [chip: file.swift ✕] [chip: shot.png ✕]                 │ ← attachment chips (only when set)
│ ┌────────────────────────────────────────────────────┐ │
│ │ Describe a coding task…                            │ │ ← auto-growing editor (1→8 lines)
│ │ [📎] [🧠 model] [🎯 Intent] [Plan] [Reasoning]  [➤]│ │ ← accessory row
│ └────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────┘
   ← animated gradient underline (ComposerFlow), brightens on focus/streaming
```

- **One elevated card**: editor + accessories in a single surface with the
  signature animated underline; hairline border that turns accent on focus.
- **No layout shift**: Intent editing lives in a popover anchored to the
  Intent button; the card never moves.
- **Auto-expanding editor**: 1 line → up to 8, then scrolls. Cursor-style.
- **Attachments**: paperclip (NSOpenPanel) or ⌘V paste; files are quoted into
  the message (bounded), images go through the vision pipeline. Chips are
  removable.
- **Accessory row**: attach, model pill (switcher popover), Intent button
  with active-count badge, Plan and Reasoning toggle chips (first-class,
  Claude-style), token estimate, send/stop.
- **Send/stop morphing**: accent-gradient arrow becomes a red stop square
  while the agent runs.
- **Keyboard**: Enter sends, Shift+Enter newline, ⌘↩ sends, Esc stops the
  agent (the only `.cancelAction` owner — the old lattice Esc conflict is
  gone), ⌘V pastes images/files.
- **Honest telemetry**: the estimate shows `≈N tok` (chars/4) of everything
  about to leave — draft + intent + resolved focus + attachments — plus a
  percentage only when the denominator is the loaded model's real context
  window (never for unknown remote windows). Tooltip carries the breakdown.

## Intent — the lattice replacement (implemented)

Per `docs/LATTICE-REDESIGN-SPEC.md` (v0.5): structured intent without the
48-cell matrix.

- **Roles** (4, binary, fixed pipeline order): Research → Build → Review →
  Verify. Each is one concrete instruction sentence the model can act on.
- **Focus** (4, availability-gated): `@files` (attachments), `@git` (branch +
  status + diff stat), `@docs` (documentation index), `@codebase` (workspace
  map). Resolvers return bounded real content; empty ones are honestly marked
  `(nothing found)`.
- **Presets** (4, role-only curations): Research first / Ship it / Test &
  verify / Full pipeline.
- **Serialization**: one labeled markdown block prepended to the user message
  (`Intent for this turn:` + role lines, `Focus:` + source lines, then
  resolved content, then the draft). No invented fences, no weights.
- **One-shot**: selection, prompt, and attachments clear on send; the draft
  (prompt + selection) persists per workspace.

## Files

- `App/ComposerView.swift` — composer card, accessory row, strips, send/stop.
- `App/IntentPicker.swift` — the Intent popover (presets, roles, focus).
- `App/ComposerStore.swift` — prompt/attachments/selection state, validation,
  token estimate, per-workspace draft persistence, send composition.
- `Core/Intent/IntentTypes.swift` — roles, focus sources, presets, composer,
  token estimator (pure Foundation, CLI-safe).
- `Core/Intent/ContextResolvers.swift` — bounded real resolvers for
  git/docs/codebase.
- `App/AgentSessionController.swift` — attachment → message expansion.
- `Core/Tools/VisionTool.swift` — image attachment descriptions.
- `Tests/IntentTests.swift` — composition, telemetry, availability, send.
