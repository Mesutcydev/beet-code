# Beet Code — UX Audit (2026-08-19)

Audit of the main window, Model Manager, Settings, and composer, driven by
dark-mode screenshots plus a full read of the App layer. Each finding lists
its resolution; items marked ✅ shipped in this pass.

## Appearance & theming

| # | Finding | Severity | Resolution |
|---|---------|----------|------------|
| A1 | Only Light/Dark/System — no identity theme despite Beet Red being the brand | Medium | ✅ New `AppAppearance.beet`: dark chrome with a plum-tinted neutral ramp derived from Pantone 19-2030 TCX (`Theme` beet hexes, resolved live at draw time) |
| A2 | Dark neutrals were one flat sheet — cards didn't lift off the window | High | ✅ (previous pass) Dark ramp re-stepped: `0C0E14 → 181C26 → 232837`, hairline `343B4E` |
| A3 | Shadows tuned for light mode; cards floated without anchoring in dark | Medium | ✅ (previous pass) `Theme.cardShadow` — 12 % black light / 45 % black dark |
| A4 | Sidebar text used raw `.secondary`/`.tertiary`, bypassing Theme tiers | Low | ✅ Routed through `Theme.textSecondary/textTertiary` |

## Typography & readability

| # | Finding | Severity | Resolution |
|---|---------|----------|------------|
| T1 | Composer input was proportional SF while every output surface (diffs, commands, diagnostics) is monospaced | Medium | ✅ `AppFont.editor` — SF Mono 14 for the composer editor |
| T2 | Assistant prose at `.callout` (12 pt) on the app's primary reading surface | Medium | ✅ `MarkdownText` bumped to `.body` (13 pt) |
| T3 | Dark text tiers sat too close to their surfaces | High | ✅ (previous pass) secondary `A3AABB`, tertiary `717889`; beet tiers match contrast (`C7AAB6` / `93727F`) |

## Layout

| # | Finding | Severity | Resolution |
|---|---------|----------|------------|
| L1 | Transcript + composer pinned to a 760 pt column — dead space both sides on a 1240 px window | High | ✅ Shared `ContentColumn.maxWidth = 1100`, one constant for both surfaces |
| L2 | Empty state hugged the top (`padding(.top, 80)`) leaving an unbalanced void below | Medium | ✅ Vertically centered with spacers |
| L3 | Empty-state glyph was a bare, washed-out SF Symbol | Low | ✅ Gradient identity tile (64 pt, white glyph, soft glow); danger variant for failed loads |

## Controls & cards

| # | Finding | Severity | Resolution |
|---|---------|----------|------------|
| C1 | Model Manager was a plain List with jagged per-row button stacks | High | ✅ Card-based manager: glyph tiles, verdict capsules, spec chips, one prominent action + overflow menu |
| C2 | Composer accessory row: five identical borderless pills, no grouping | Medium | ✅ Clustered (context / behavior / commit) with a divider; resting pills now have hairline borders; model pill carries a status dot + ready-state accent border |
| C3 | Settings BYOK intro was a full card around one paragraph — read as a runt next to provider cards | Medium | ✅ Slim `InfoBanner`; key-restore card → warning banner; provider cards got the shared icon-header chrome |
| C4 | Approval/Question/Plan cards: no visual hierarchy (all-default buttons), unstyled answer field, diff counts overlapping content | High | ✅ Shared `TranscriptCardHeader` (tinted tile + title + tool chip), prominent accent primary action, rounded answer field, diff +/− moved to a header row |
| C5 | Finish banners were floating bare text | Low | ✅ Tinted status pills; engine errors get a wash card |

## Known items, not yet addressed

- Chip-level literal paddings in ChatView/ComposerView (local and
  internally consistent; converting to `Spacing` is churn with no visual
  delta).
- Status bar neutral chip fill uses a 0.6-opacity inset — deliberate
  translucency, but it is the one neutral fill that bypasses the Theme.
- No snapshot/visual regression tests for any of these surfaces; the
  304-test suite covers logic only. A Swift snapshot pass would lock these
  designs in.
