# Beet Code Brand Kit

The single reference for how Beet Code looks. Code-level source of truth is
`App/Theme.swift` — this document is the human-readable contract; when the two
disagree, fix the code to match the intent written here, not the reverse.

## 1. Brand color

**Beet Red — Pantone 19-2030 TCX — `#7A1F3D`.**

This is the identity. It is not an accent sprinkled on gray: in the signature
**Beet appearance** it *is* the window background, with every surface derived
from it as a lightness step of the same hue. In Light/Dark appearances it is
the default accent palette entry (`AccentPalette.beetRed`).

| Role | Light | Dark | Beet |
|---|---|---|---|
| `bg` (window) | `#F6F7F9` | `#0C0E14` | **`#7A1F3D` (exact Pantone)** |
| `surface` (cards) | `#FFFFFF` | `#181C26` | `#90304E` |
| `surfaceInset` (wells/chips) | `#E3E6EB` | `#232837` | `#5E1630` |
| `hairline` (borders) | `#E1E4EA` | `#343B4E` | `#A84668` |
| `textPrimary` | `#14161A` | `#F2F4F8` | `#FDF2F6` |
| `textSecondary` | `#5B616E` | `#A3AABB` | `#E7B8C8` |
| `textTertiary` | `#8A909C` | `#717889` | `#C08CA0` |

Beet rules:

1. **One hue, four depths.** Beet neutrals never drift gray or blue — every
   step stays inside the beet family (hue ≈ 334°).
2. **Cards lift lighter, wells sink darker.** Never invert this.
3. **No system materials in Beet mode.** Materials resolve neutral gray and
   break the ramp; `lfGlass` already falls back to opaque themed surfaces.
4. Text contrast on the Pantone background: primary ≈ 10:1, secondary ≈ 5.6:1,
   tertiary ≈ 3.5:1 (supplementary text only).

## 2. Accent palettes

Switchable in Settings → Appearance. Every palette ships four hexes: accent
and bright variant, each for light and dark (`AccentPalette.Hexes`).
`beetRed` is the default; `indigo`, `ocean`, `forest`, `amber`, `graphite`
are alternatives. Dark variants always lift the hue so the accent stays vivid
on black/beet.

Tint washes are the ONLY allowed opacities for tinted fills/borders:

- `wash(tint)` — 0.10 fill
- `washStrong(tint)` — 0.16 fill
- `washBorder(tint)` — 0.35 border

## 3. Status colors

| Token | Light | Dark | Use |
|---|---|---|---|
| `success` | `#1EA672` | `#35D6A0` | ready engine, passed steps, checkpoints |
| `warning` | `#C77700` | `#F5B23D` | approvals, loading, marginal memory |
| `danger` | `#DC3B4B` | `#FF6B78` | failures, destructive actions, stop |
| `info` | `#2B7FFF` | `#5AA0FF` | questions, focus sources, neutral info |

## 4. Typography

- Prose and UI: SF (system). Assistant transcript prose at `.body`.
- Anything the user *types* as a coding task and anything machine-emitted
  (diffs, commands, diagnostics, tool names): SF Mono — `AppFont.editor`
  (14 pt) for input, `.caption.monospaced()` for output.
- Hierarchy: `.headline` section headers → `.callout` primary rows →
  `.caption` secondary → `.caption2` metadata. Metadata digits are always
  `.monospacedDigit()`.
- Labels inside pills never wrap: `.lineLimit(1)` + `.fixedSize()` is part of
  the pill contract (`lfComposerPill`).

## 5. Shape and space

- Radius scale (`Radius`): sm 7 · md 11 · lg 15 · xl 20. Continuous corners.
- Spacing (`Spacing`, 4-pt grid): xs 4 · sm 8 · md 12 · lg 16 · xl 20.
  No ad-hoc padding literals.
- The transcript and composer share one centered column,
  `ContentColumn.maxWidth` (1100 pt), fluid below that.

## 6. Component language

- **Pills** (composer accessory row, filter pills, suggestion chips):
  capsule, `surfaceInset` fill + `hairline` border at rest; accent wash +
  accent border + accent text when active. Caption weight medium, 11 pt icons.
- **Cards**: `Theme.surface` + 1-pt hairline, `Radius.lg` (`lfCard`); semantic
  state cards (approval/question/plan/error) use `lfWashCard(tint)`.
- **Group headers** (sidebar): accent-filled icon tile + headline name +
  count pill on `surfaceInset` card; chevron rotates on collapse. Headers are
  always tappable cards, never plain text rows.
- **Elevation**: `Theme.cardShadow` — a whisper in light, deep in dark/beet.
- **Identity**: the beet logo (`BeetLogo` asset) is the assistant's avatar —
  26 pt, 30 % corner radius, accent glow. The composer's animated gradient
  border is the signature motion; it must trace the full perimeter and
  respect Reduce Motion (static gradient instead).

## 7. Motion

- One signature animation (composer border). Everything else is short and
  functional: ≤ 0.16 s ease-in-out for expand/collapse and state changes.
- Every animation has a Reduce Motion fallback that keeps the state change
  and drops the movement.
