# Beet Code — UX Audit: Interaction Details

Generated 2026-08-18 by direct code reading — written in-house after repeated
subagent API-timeout failures. Items marked ✅ were fixed during this session.

## Findings

| # | Area | Finding | Sev | Fix |
| --- | --- | --- | --- | --- |
| 1 | Hover states | Lattice cells/headers/accessory controls ✅ fixed today. Still missing: sidebar session rows, Model Manager rows, attachment chips, simulator panel buttons. | P1 | Apply the same hover-brightness modifier project-wide. |
| 2 | Loading feedback | Model load shows "Loading X…" in sidebar only — main area stays on the empty state. No pre-first-token indicator for remote requests. | P1 | Show a phase chip in the transcript ("Loading model…", "Contacting provider…") driven by `enginePhase`/task phase. |
| 3 | Keyboard | ⌘, Settings ✅ · ⇧⌘M Model Manager ✅ · Esc: lattice/simulator/stop ✅ · Return sends ✅. **Gap:** no newline shortcut in the composer (TextField.onSubmit swallows Return); no ⌘K command palette (Cursor/ZCode parity). | P0 | Document/implement Option+Return for newline; add a ⌘K palette (models, workspaces, sessions, actions). |
| 4 | Scroll | Transcript follow-mode exists (`onScrollGeometryChange` + transcript-count onChange). Lattice no longer scrolls (fixed). Sidebar sessions capped at 10 with no overflow affordance. | P2 | "Show all sessions" disclosure when >10. |
| 5 | Animations | Lattice panel scale+fade ✅. Missing: approval/plan card entrance, session-switch crossfade (hard swap), diagnostics breadcrumb appearance. | P1 | `.transition(.opacity.combined(with: .move(edge: .bottom)))` on cards; `.animation` on transcript container keyed by session id. |
| 6 | Hit targets | Accessory controls now ≥28pt ✅. Chip close buttons (7pt xmark ≈ 16pt effective) are below target: attachment chips, lattice chips, queued-message chips. | P1 | Grow chip hit area to 24pt with `.contentShape` padding. |
| 7 | Status bar | Redesigned as monospaced chip segments ✅. | — | — |
| 8 | Sidebar | Session rows now distinguishable (msg count + relative time) ✅. Model state clear; Load-failed dismissible ✅. | — | — |
| 9 | Empty states | Distinct error vs setup glyph ✅. Missing CTA buttons (see flows audit #1). | P1 | Buttons in `emptyState`. |
| 10 | Cursor feedback | No control in the app pushes a pointing cursor — custom clickable surfaces (lattice cells, chips, session rows, headers) all show the default arrow. | P1 | Shared `pointingCursor()` modifier: `.onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }`. |

## Accessibility

- `reduceTransparency` honored by `lfGlass` ✅; **reduceMotion not yet gated**
  on the composer TimelineView — gate `animated` on
  `@Environment(\.accessibilityReduceMotion)` too.
- Labels: icon-only buttons have `.help` ✅ but no `accessibilityLabel` on
  the paperclip/send/stop buttons — add them.
- Contrast: light-mode `.surfaceInset` fills run flat (noted in UI-POLISH-AUDIT U9).

## 5 highest-leverage improvements

1. **⌘K command palette** — single biggest Cursor-class upgrade; routes
   models/workspaces/sessions/settings without mouse hunting.
2. **Empty-state CTA buttons** — turns a description into a path.
3. **Pointing cursor + hover lift everywhere** — cheap, makes every custom
   surface read as interactive (Vamp/Cursor polish).
4. **Reduce-motion gating + card transitions** — completes the animation story.
5. **Composer newline shortcut** (Option+Return) with a placeholder hint.
