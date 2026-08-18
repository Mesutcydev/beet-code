# Composer + Lattice redesign spec

> **Status: implemented (2026-08-18), with one deviation.** The matrix is
> gone and the Esc conflict is fixed, but the selection surface became the
> Intent picker popover (presets → role chips → focus chips, per
> `LATTICE-REDESIGN-SPEC.md`) instead of the palette described here — the
> optional grid was not carried over at all.

Drafted from direct code reading; two delegated design passes will refine before build.

## Current diagnosis (verified in code)

### Broken logic
1. **48-cell matrix maximizes discoverability cost**: 6 roles × 8 contexts, but
   users realistically activate 2–3. The grid encodes combinatorics the
   prompt doesn't need.
2. **Tri-state cells (idle/active/muted) are unusable**: one click toggles
   idle↔active; muted is only reachable through budget-pruning (engine calls
   it muted) or unmarked option-click cycling. Nothing shows the user what a
   click will do or why muted exists.
3. **"[lattice] …" preamble is wasteful**: fences harm small-model token
   efficiency; per-title weight suffixes (`(weight: HIGH 0.90)`) add noise.
   Roles sorted by a hardcoded row-priority map that may not match intent.
4. **Telemetry lies about honesty**: "TOKENS" is an internal estimate from an
   arbitrary index (12 hard chars/4); public label implies it's real counts.
5. **Superposition dead control**: `model.superposition.toggle()` flips a
   boolean; nothing consumes it. A toggle in the UI must do something or go.
6. **Presets are decent but hidden**: work great (cells auto-activate), but
   they're behind the grid.

### Broken UX
1. **Esc conflict** in ChatView: `lattice-close .cancelAction` + `stop-agent
   .cancelAction` — macOS routes the shortcut unpredictably.
2. **Inline expansion pushes the input down**; attachments and the composer
   row shift instead of being covered.
3. **Chip/preset/accessory clutter**: lattice button + plan toggle +
   reasoning toggle + superposition + attachments … seven controls at ≤12pt.

## Redesign (Logic)

Drop the matrix as the primary UI. Keep the *idea* (structured intent via
roles + context) but encode it as **chips you add via a palette**:

1. **Selection model**: `Set<LatticeCellID>` — two states only. One click ON,
   click again OFF. `.muted` gone forever; engine pruning simply marks pruned
   cells without a silent third state.
2. **Palette-not-grid**: the expanded panel is a *palette* — role chips on
   the left, context columns on the right; clicking a role then a context
   adds the chip. Optional grid stays as "advanced" inside a popover/sheet.
3. **Presets first**: the preset row is the top-level discoverability
   surface (ship/research/pipeline/verify), no longer buried under the grid;
   empty when no selection.
4. **Prompt format**: replace `[lattice]` fences and weight suffixes with an
   explicit structured block:
   ```
   <intents>
   <role>builder</role>
   <instruction>Implement the change carefully, file by file.</instruction>
   <context>@files</context>
   </intents>
   ```
   …joined cleanly per activated cell; sorted by a small priority table the
   model can read. Budget uses the composed final content only (no └weights).
5. **Honest telemetry**: token strip renamed "EST. TOKENS" and % is against
   a documented budget (e.g. of 32k); no implication it's exact.
6. **Kill Superposition**: remove the control and the flag until there is a
   real branch-parallel feature behind it.

## Redesign (UX)

1. **One Esc owner**: composer is the diaphragm — Esc closes the lattice when
   expanded; when collapsed Agent stops. Remove the duplicate `.cancelAction`.
2. **No layout shift**: expanded lattice presents as a **sheet/popover
   floating over the transcript**, anchored to the composer; the composition
   row (attach+input+send, lattice+plan+reasoning toggles) never moves.
3. **Accessories unified**: single segmented menu with Lattice / Plan /
   Reasoning (superposition gone); lattice shows a badge with active count.
4. **Grid optional**: `moreInteraction.state.grid()` to toggle grid; default
   palette. All interactions one/two-click only.

## Scope guard
Build the new state machine (selection-only), the popover/sheet UI, the Esc
fix, the preamble format, chips→preset first, telemetry re-label, remove
Superposition, drop grid to advanced popover. Wire into existing
`LatticeModel` & `LatticeEngine` (one replacement each).
