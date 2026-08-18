# Beet Code — UI Polish Audit

Generated 2026-08-18 by direct visual + code verification. Subagent attempts
for this task hit API timeouts; this is written from what was actually seen
in-app (screenshots) and read in source. Settings and Lattice were rebuilt in
this session — judged on current state.

## What was verified working (live screenshots)

- **Settings window**: 780×620 tabbed (General / Agent / Providers), card
  components, per-provider endpoint + Test button, badges. Opens, tabs switch,
  no truncation.
- **Lattice panel**: full 6×8 grid, header + telemetry strip, presets,
  hover states, staggered spring entrance. Renders at full width.
- **Model Manager**: catalog rows, Import…, Remote (BYOK), download states.
- **Composer**: animated border flows, send/queue, accessory row.
- **Main window**: sidebar, empty states, status bar all render.

## Findings

| ID | Sev | Location | Issue | Fix |
| --- | --- | --- | --- | --- |
| U1 | ~~High~~ ✅ FIXED | `MainWindowView.swift` sidebar | "Recent Sessions" shows repeated bare titles ("write new.txt" ×2, "task" ×3) with only a duration — no timestamp, no way to distinguish sessions. Looks broken even though it isn't. | Add relative timestamp (e.g. "2h ago") + dedupe display by appending a short session id or index; consider grouping by day. |
| U2 | ~~High~~ ✅ FIXED | `MainWindowView.swift` | Stale "Load failed" reason persists in sidebar after the broken model is removed/relaunched. Error state not cleared on workspace/model change. | Clear the model-load error on any successful activate/unload/workspace switch. |
| U3 | ~~High~~ ✅ FIXED | `ModelManagerView.swift` | Small metadata lines (context/RAM) render blurry/partially illegible at default sheet size; verdict badges crowd the title row. | Bump caption metadata to `.callout`, give the sheet a min width ~700, add spacing between badge row and metadata. |
| U4 | ~~Medium~~ ✅ FIXED | `StatusBarView.swift` | Status bar is a dense single line ("No model · RAM 59,5 MB / 11,98 GB free budget · Cool · CPU 14%") with mixed units and comma decimals. Hard to scan. | Use monospaced digits, consistent units, and a visual separator or segmented chips; align with telemetry-strip style already in the lattice. |
| U5 | ~~Medium~~ ✅ FIXED | `ChatView.swift` composer accessory row | Model chip ("local LOCAL"), Lattice/Plan/Reasoning buttons have no hover states and inconsistent hit heights vs the composer's own buttons. | Add `.onHover` brightness lift + uniform 28pt min hit targets (Vamp BrandCard pattern). |
| U6 | ~~Medium~~ ✅ FIXED | `ChatView.swift` transcript | Empty/error states center the same purple hammer icon for both "no model" and "load failed" — only the heading text differs. Easy to miss which state you're in. | Distinct icon + color per state (hammer for setup, warning triangle in danger tint for failure). |
| U7 | ~~Medium~~ ✅ FIXED | `LatticeComposer.swift` | Column/row header buttons are a good addition but have no visible affordance that they're clickable (no hover cursor/hint beyond tooltip). | Add hover tint + pointing cursor on header buttons. |
| U8 | ~~Low~~ ✅ FIXED | `SettingsView.swift` | Provider Test result line reserves 16pt min height — good — but long error bodies can still exceed 2 lines and push the card. | Cap at 3 lines + `.lineLimit` with expandable disclosure. |
| U9 | ~~Low~~ ✅ FIXED | Global | Light mode is the default; several surfaces (telemetry bar, chips) were tuned for dark and read slightly flat in light. | Light `surfaceInset` darkened one step (0xEDEFF3 → 0xE3E6EB) so inset wells/chips keep visible separation. |

## 2026-08-18 — Cursor/ChatGPT-style transcript polish

The transcript was restyled to match the Cursor/ChatGPT reading pattern:

- **Centered 760pt content column** — on wide windows the prose never
  stretches edge-to-edge; it stays at a readable measure, centered.
- **Avatar-led assistant messages** — no bubble; a gradient sparkles tile
  (`AssistantAvatar`) gives output a face, full column width, inline
  markdown rendering (`MarkdownText`, with plain-text fallback).
- **Grouped tool activity** — consecutive tool calls/results/reasoning
  collapse into one `ToolStepsCard` with a step-count header, outcome badge,
  and expandable per-step rows. A run reads as "answer, work, answer".
- **Streaming caret** — a blinking `▍` follows live output (solid under
  Reduce Motion), replacing the bouncing-dots indicator.
- **Suggestion chips** — ChatGPT-style quick prompts in the empty state,
  only shown when a model can actually run; one tap fills the composer.
- **Hover affordances (U5)** — `lfHoverLift()` (pointer cursor + brightness
  lift) on attachment chips + suggestion chips.

## Already polished

- Theme token discipline is strong: `Theme.*` + `Radius.*` + `lfCard/lfWashCard`
  used consistently; very few hardcoded colors.
- Composer animated border (idle→focused→streaming intensification) is a
  genuine signature move.
- Settings card components give consistent padding/typography/footers.

## Glass (Vamp recipe) — applied + recommended

`lfGlass()` was ported from `MacClient/Sources/MacBrand.swift` into
`Theme.swift` this session (geometry-locked glass, `.regular` for content,
`.clear` for chrome, material fallbacks pre-macOS 26, Reduce-Transparency
fallback, +0.025 hover lift). Applied to: lattice panel, Settings cards,
Model Manager backdrop.

**Signature moves to reach Cursor-class + Vamp glass:**
1. Glass on the composer input well + transcript bubbles (not just panels).
2. A real window backdrop (`MacWindowBackdrop`-style clear glass) so surfaces
   refract the desktop — currently the window uses an opaque `Theme.bg`.
3. Hover-lift + pointing cursor on every interactive chip/cell/header.
4. Monospaced-digit telemetry everywhere (status bar + lattice + tok/s).
5. Session list with relative timestamps + day grouping (fixes U1).

## Accessibility quick-pass

- Hit targets: most accessory buttons are `.controlSize(.small)` (~24pt) —
  below the 28pt recommendation (U5).
- `reduceTransparency` is honored by `lfGlass` (good); no `reduceMotion`
  guard yet on the composer TimelineView animation — gate it.
- Color-only states (Configured badge uses icon + color: good).
