# Beet Code — Tracked Issues & Requests

Living punch-list from user feedback. [x] = done, [ ] = open.

## P0 — Stability
- [x] Launch crash (SwiftUI AttributeGraph: invalid view signature / NaN /
  infinite size). Caused by the Lattice grid living in the always-on input
  bar. Fixed: the lattice now presents as a sheet; the input bar and launch
  layout are untouched. Verified: app launches and stays alive; 157 tests pass.

## P0 — Lattice Composer in place (asked 5×)
- [x] Present in the app: a Lattice toggle in the composer accessory row opens
  a sheet with the roles × contexts grid + intent-assembly chips; activated
  cells inject a structured [lattice] intent block into the sent message.
- [x] Premium composer redesign (native): the Lattice is now the composer —
  inline expandable living lattice (stateful cells), telemetry strip (tokens /
  budget / cells + utilization bar), intent chips, superposition toggle, and a
  LOCAL/REMOTE model badge with tok/s semantics. Replaces the old sheet;
  Esc/Collapse closes it. Launch-stable (HStack rows) + 166 tests green.
- [x] Full Intent Lattice repair (2026-08-18): information architecture,
  interaction logic, and state machine rebuilt chips-first — single-source-of-
  truth store, availability-gated cells, presets with skip explanations,
  derived Plan/Activity tabs, immutable run snapshots, robust cancel phase
  transitions. 36 new tests. The web reference (lattice-composer/) is retired;
  the native composer supersedes it — no inspector/branch rail carried over.
- [x] Native LatticeEngine port: composition + budgeting + dynamic estimation in
  Core/Lattice/LatticeEngine.swift (pure, Foundation-only), bridged into the
  composer (contextPreamble + live budget readout). 9 new tests; 166 total green.

## P1 — Appearance config location
- [x] Light/dark (Appearance) lives in Settings > Appearance only; nothing
  appearance-related is in the composer. Light is the default.

## P1 — Recent sessions selectable
- [x] Clicking a Recent Session row now calls restore(record), re-pointing the
  workspace and resuming the persisted session.

## P2 — Simulators
- [x] Simulators boot (off-main simctl + bootstatus + generation-guarded stream).

## Done — branding
- [x] App icon: the beet (</>) image is now the app icon
  (App/Assets.xcassets/AppIcon.appiconset, all macOS sizes) via asset catalog.
- [x] Accent color #7A1F3D set as the global AccentColor (asset catalog), so
  Color.accentColor and control tint use the brand maroon app-wide.
- [x] Composer placeholder branched: "Open a workspace…" vs "Load a model…" so
  a missing-model workspace never pretends the workspace is missing (UX audit gap).

## 2026-08-18 — Hooks + placeholder batch
- [x] **Hooks**: `Core/Agent/HookRunner.swift` — subprocess JSON hooks
  (`PreToolUse` can `allow`/`deny`/`rewrite`, `PostToolUse`/`Stop` are
  observational). Hook crash/timeout is fail-open; only explicit `deny` blocks.
  They **cannot bypass** the permission gate (hooks run after the gate
  would have asked; a rewrite feeds the same gate). Tested (HookRunner +
  AgentLoop integration, both the deny-rewrite and the gate-bypass cases).
