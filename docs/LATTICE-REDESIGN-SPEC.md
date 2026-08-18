# Lattice Composer — Logic Redesign Spec (v0.5)

Scope: **interaction logic and prompt-injection logic** of the Lattice Composer
(`App/LatticeComposer.swift`, `App/ChatView.swift`, `Core/Lattice/LatticeEngine.swift`).
Not a visual redesign; visual changes follow from the logic model defined here.

---

## 1. Audit — what the current logic actually does

Read across `LatticeComposer.swift`, `ChatView.swift` and `LatticeEngine.swift`,
the feature's logic is thinner than its surface suggests. Five structural
findings, each answering one of the review questions.

### 1.1 The role × context matrix is over-engineered — the context axis is inert

- There are 48 cells, but only **6 distinct prompt sentences** exist
  (`LatticeRole.instruction`). The 8 context columns contribute **nothing** to
  the prompt: `LatticeModel.contextPreamble()` calls
  `LatticeEngine.budgetAwareCompose(engineState())` **without a resolver**, and
  the engine's default resolver is `{ _ in [] }`. With empty resolution, the
  composed block per cell is just `cell.promptFragment` = the role instruction.
  Toggling `(builder, files)` vs `(builder, git)` produces byte-identical
  prompt text, differing only in cell-ID sort order and chip label.
- Worse, it has a **duplication bug**: two active cells of the same role inject
  the same instruction sentence twice. The shipped preset "Research first"
  contains `(.researcher, .codebase)` and `(.researcher, .docs)`, so it injects
  "Gather the relevant code and context before making changes." **twice** in
  one preamble — wasted tokens and degraded prompt hygiene.
- The promised "priority-sorted" ordering is dead code: the engine's
  `rowPriority` table keys (`plan/reason/ask/implement/verify/background`)
  never match the UI role raw values (`orchestrator/planner/builder/…`), so
  every cell falls to `defaultPriority = 100`, weight is hardcoded `0.9`, and
  the tie-break is **alphabetical by cell ID**. Ordering is arbitrary, not
  priority-driven.

**Verdict: the 6×8 matrix is the wrong primitive.** Users toggle ~3 cells
because only one axis carries signal. The matrix manufactures combinatorial
richness (48 cells, 6 colors, row/column bulk-toggles, count pills) while
delivering 6 sentences.

### 1.2 The `.muted` mid-state is unreachable clutter

- `LatticeModel.toggle(_:muted:)` accepts a `muted` flag, but **no callsite
  ever passes `muted: true`** — every UI path calls `toggle(id)` and the
  comment-claimed "option-click" handler was never implemented (cell help text:
  "click to toggle").
- The engine's prune path sets `status = "muted"` only on its **local copy**
  of the state (`budgetAwareCompose` copies cells); the UI's `cells` dictionary
  is untouched, so pruned cells still render as active.
- Result: a whole third cell state with dedicated rendering (`fill`, `border`,
  size rules) and engine semantics (`status != "muted"` filters) that the user
  can neither reach nor observe. Pure clutter.

### 1.3 The prompt fence format is noisy and miscategorized

Current injection, prepended to the **user message**:

```
[lattice]
### BUILDER (weight: HIGH 0.90)
Implement the change carefully, file by file.

### TESTER (weight: HIGH 0.90)
Verify with builds/tests and report failures precisely.
[/lattice]
```

Problems:

1. **Weight metadata is model-facing junk.** `HIGH 0.90` labels imply a system
   the model can act on; it cannot (all weights are 0.9 anyway). HIGH/MEDIUM/LOW
   tier text is unreachable beyond HIGH because `engineState()` hardcodes 0.9.
2. **Invented fence.** `[lattice]…[/lattice]` is not a convention any model
   knows; a plain labeled markdown block is parsed better and reads better on
   the transcript.
3. **Category error.** The engine names its output `systemBlocks`/`systemContent`
   but the composer concatenates it onto the **user message** (`message =
   preamble + "\n\n" + text`). It is user-authored intent, and should be
   modeled and named as such.
4. **`[files]`-style "Context" sections never appear in production** because
   resolution is never wired (see 1.1) — yet the format reserves a whole
   `--- Context ---` machinery for it.
5. **Chip labels overclaim.** Chips render "Builder · @files", implying the
   model receives an `@files` mention; it never sees the token.

### 1.4 Token-budget telemetry is not truthful

- **Estimator:** `chars/4 + words·0.15 + punctuation·0.3 + newlines·0.5 + 4` is
  an ad-hoc blend that wanders both above and below the standard chars/4
  heuristic; there is no calibration basis for the fudge terms, and the formula
  is presented to the user as an exact count.
- **Wrong denominator.** `hardLimit 32_000 / softLimit 24_000` are static
  constants while the app legitimately knows the real budget: every catalog
  model carries `contextWindow` (32K/64K/128K) and `AgentLoop.Configuration.
  contextWindowTokens` is already plumbed. Typical preamble usage is 60–100
  tokens → the meter reads ~0.3% forever. It is decorative, not telemetry.
- **Wrong numerator.** `freeText` is hardcoded `""`, so the user's draft,
  attachments, and the existing conversation usage are all excluded from the
  "budget" — precisely the terms that actually consume context.
- **No resolution, nothing to budget.** Since context resolution returns empty
  (1.1), the only thing ever counted is ~15 tokens/role. The prune machinery
  (soft/hard limits, locked cells, lowest-priority-first) is unreachable in
  practice.
- Related dead code: `draftLooksComplex` (auto-expand heuristic) is defined in
  `ChatView` and **never called**; the `Superposition` toggle flips a
  `@Published` flag **nothing consumes**.

### 1.5 Presets encode the duplication bug; curation is mostly right

| Preset | Cells | Issues |
| --- | --- | --- |
| Ship it | builder×files, tester×tests, reviewer×codebase | Fine roles; context tags pure noise |
| Research first | researcher×codebase, researcher×docs, planner×docs | **Duplicates researcher twice** (bug 1.1/1.2), double-taps planner+researcher |
| Full pipeline | orchestrator×git, planner×files, builder×codebase, reviewer×codebase, tester×tests | Orchestrator is meta-commentary, not a per-turn instruction the model can obey |
| Test & verify | tester×terminal, tester×tests, reviewer×git | Duplicates tester twice |

The workflow names are the right vocabulary (they mirror the app's own
`AgentPhase`: planning → working → verifying). What is wrong is that they are
expressed in coordinates on an axis that carries no signal.

---

## 2. The new logic model

### 2.1 One-sentence model

> **A message carries an optional *Intent*: a deduplicated, ordered set of
> Roles (behavior directives for this turn) plus an optional *Focus*: a set of
> @-mention sources that resolve to real content — or are honestly empty.**

Two dimensions, kept strictly orthogonal, neither rendered as a matrix:

- **Roles** — 4 chips, multi-select, fixed pipeline order.
- **Focus** — 4 chips, multi-select, each with a **resolver** that either
  produces bounded content or reports `empty`.

User-visible primitive count drops from 48 cells to **8 chips + 4 presets**.

### 2.2 Roles — keep four, delete two

Keep roles; they are the only element with prompt semantics and they map to
real agent behavior. Reduce to four, and stop duplicating app-level controls:

| Role | Keep/drop | Rationale |
| --- | --- | --- |
| **Research** | keep | genuine per-turn directive |
| **Plan** | **remove from lattice** — merge into the existing **Plan toggle** in the accessory row (`settings.planMode`), which already implements propose-before-acting with an approval gate. Having two plan flags is a logic fork the user must reconcile. | |
| **Build** | keep | the default working directive |
| **Review** | keep | distinct from verify (static critique vs. dynamic confirmation) |
| **Verify** | keep | maps to `AgentPhase.verifying` |
| **Orchestrator** | **drop** | "Coordinate the steps…" is meta-commentary; a single-agent loop cannot act on it, and the role never produces observable behavior. |

Fixed semantic order (used for composition and chip display):
**Research → Build → Review → Verify.**

Selection rule: **set semantics, not multiset**. A role is either selected or
not; duplication is impossible by construction.

### 2.3 Focus sources — four, each with a real resolver

The old 8 columns shrink to 4 sources that can actually be resolved and
bounded. Every Focus chip must declare its resolver; if resolution returns
zero content the chip shows an `(empty)` suffix in the preamble (honesty) and
contributes only the `@`-token.

| Focus | Resolver | Notes |
| --- | --- | --- |
| `@files` | attached `ComposerAttachment`s (existing chip pipeline) | reinstate the old column on top of a mechanism that already works |
| `@git` | `git status --short` + bounded `git diff` (cap, e.g. 8k chars) | only when the workspace is a repo |
| `@docs` | bounded concatenation of `docs/*.md` or docs search results | cap, e.g. 8k chars |
| `@codebase` | top-N workspace search hits against the prompt (existing search tool) | cap; honors `Workspace` confinement |

Dropped sources and why: `@terminal` (no resolver exists; transcript is not
context), `@memory` (already injected by the app's memory pipeline — don't
double-inject), `@tools` (tool definitions are a system-prompt concern, not a
per-turn hint), `@tests` (a subset of @files/@codebase — pick files instead).

### 2.4 Two states, honestly labeled

- Cells/chips are **binary**. Delete `LatticeCellState.muted`.
- Budget pruning never silently deactivates. When focus content is dropped to
  fit, the chip remains selected but renders in a warning tint with tooltip
  "content dropped to fit the context budget", and `BudgetStatus.pruned*`
  (agent-visible) records it. The existing engine fields (`locked`,
  `prunedCellIds`) survive; the invisible mid-state does not.

### 2.5 Presets — role-only curations

Presets become **named role sets** (replace-selection semantics unchanged):

| Preset | Roles | One-line meaning |
| --- | --- | --- |
| **Research first** | Research | gather context, then answer; change nothing |
| **Ship it** | Build, Verify | implement, then prove it builds/tests |
| **Test & verify** | Verify, Review | run the suite and critique the result |
| **Full pipeline** | Research, Build, Review, Verify | everything, in pipeline order |

(If the Plan-merge of §2.2 is adopted, "Plan first" is not a preset — it's the
existing Plan toggle, and presets must not fight it.)

### 2.6 Interaction skeleton (logic, not visuals)

- Accessory row keeps one **Lattice/Intent** toggle that expands the panel.
- Panel contents, top-down: **presets row → role chips row → focus chips row →
  telemetry line**. No grid, no row/column bulk-toggles, no count pills.
- Chips strip below the input is the single source of truth (`Role · @focus`
  items), each individually removable; "Clear all" stays.
- Introduced semantics: **selection persists while a run is in flight** (today
  `clear()` fires on send; keep that, it's correct one-shot behavior).
- `draftLooksComplex`: **delete** (dead) rather than wire it. Expansion is a
  user choice; unexpected UI movement is worse than a missed suggestion.

---

## 3. Prompt-injection spec

### 3.1 Placement & naming

- The block is **user-authored intent**, prepended to the outgoing user
  message — exactly where it sits today — but the engine must stop naming it
  `systemContent`. Rename to `intentContent` / `ComposedIntent`.
- Injected at most once per send; empty selection ⇒ no block, message
  untouched (existing behavior, keep).

### 3.2 Inject only what's true

Rules:

1. **Roles are deduped by construction** (set semantics) — never repeat an
   instruction.
2. **Fixed order** in every block: Research, Build, Review, Verify.
3. **No weights, no tiers, no numeric metadata** — the model can act on
   instructions, not on `0.90`.
4. **No invented fences** — one labeled markdown section. `[lattice]…[/lattice]` retires.
5. **Focus lines state what was actually included**; unresolved sources are
   marked `(nothing found)` and never fabricate a section.

### 3.3 Exact template

```
Intent for this turn:
- Research: Read the relevant code and project context before proposing or making changes; never guess what's in a file.
- Build: Implement the change file by file; keep each edit minimal and say what changed and why.
- Review: Check the change for correctness, edge cases, and style; report concerns by severity.
- Verify: Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output.

Focus:
- @git — current branch and uncommitted diff appended below.
- @files — attached: Foo.swift, FooTests.swift.
- @docs — (nothing found).
```

Emit only selected roles, in fixed order. Emit the `Focus:` section only when
at least one focus chip is selected; emit a line per selected chip, resolved
content appended **after** the preamble in the order the chips were selected,
each bounded by its resolver cap.

### 3.4 Exact per-role instruction text (final strings)

- **Research**
  `Research: Read the relevant code and project context before proposing or making changes; never guess what's in a file.`
- **Build**
  `Build: Implement the change file by file; keep each edit minimal and say what changed and why.`
- **Review**
  `Review: Check the change for correctness, edge cases, and style; report concerns by severity.`
- **Verify**
  `Verify: Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output.`

Single instruction per role; ~20 tokens each. Four roles ≈ 80 tokens —
irrelevant against any real context window, which is why the telemetry (§4)
must stop pretending this is a budget concern.

### 3.5 Worked example (presets "Ship it" + focus @git, no draft hacking)

```
Intent for this turn:
- Build: Implement the change file by file; keep each edit minimal and say what changed and why.
- Verify: Run the relevant builds/tests after editing; if anything fails, report the exact command and the key output.

Focus:
- @git — current branch and uncommitted diff appended below.

<resolved @git content, bounded>

Add a settings toggle for the lattice panel.
```

---

## 4. Token telemetry spec — replace estimation theater with honest accounting

1. **Estimator:** one formula — tokens ≈ `max(1, ceil(chars/4))` — declared
   as an estimate, displayed with `≈`. Where the active engine exposes a real
   tokenizer (MLX models on-device), use it and display without `≈`. Delete
   the punctuation/newline/word fudge terms.
2. **Denominator:** the loaded model's actual `contextWindow` (already in the
   catalog) minus currently-committed session usage minus response reserve.
   If the denominator is unknown (custom remote endpoint), **show absolute
   tokens only — no percentage**; a percentage of a fictitious 32K is worse
   than no percentage.
3. **Numerator:** everything about to leave: draft + role text + resolved
   focus content + attachment estimates. Breakdown on hover
   (`draft 312 tok · focus 1,240 tok · intent 78 tok · 2 attachments ~600 tok`).
4. **Display budget:** three states — green <50%, amber 50–80%, red >80% —
   thresholds tied to the real remaining window; drop the
   softLimit/hardLimit/warnings trio which warns about limits nothing
   approaches in practice today.
5. **Pruning policy (when it actually matters — focus content):** drop
   lowest-priority focus sources first (@codebase, then @docs, then @git,
   then @files), respect `locked`, surface drops via the §2.4 warning tint.
   Role instructions are never pruned (they are the intent; at 80 tokens they
   never need to be).

---

## 5. Migration map

| Current | Disposition |
| --- | --- |
| `LatticeRole` (6) | → `IntentRole` (4): research/build/review/verify; orchestrator, planner deleted |
| `LatticeContext` (8) | → `FocusSource` (4): files/git/docs/codebase, each with `resolver` |
| `LatticeCellID` (pair) | deleted — no pairs exist |
| `LatticeCellState.muted` | deleted; binary selection |
| row/column bulk toggles, count pills | deleted with the grid |
| `LatticeModel.toggle(_:muted:)` | → `select/deselect` set ops |
| `Preset.cells: [(role, context)]` | → `roles: [IntentRole]` |
| `LatticeEngine.rowPriority` table | → fixed `IntentRole.order` |
| weight encoding, HIGH/MEDIUM/LOW | deleted |
| `compose`/`pruneToBudget` machinery | retained, fed by resolvers; pruned items surface in UI |
| `[lattice]` fence + `### ROLE` headers | → §3.3 template |
| `estimateTokens` fudge | → chars/4 (+exact tokenizer when available) |
| `TokenBudgetConfig(hard 32k/soft 24k)` | → live `contextWindow − usage − reserve` |
| `SuperpositionToggle` | remove from composer (no consumer exists) |
| `draftLooksComplex` | delete |

## 6. Test updates (`LatticeEngineTests`)

- Assert role dedup: a selection set can never inject a role line twice
  (previously the preset bug).
- Assert fixed order: build-before-verify compositions regardless of insertion
  order.
- Assert empty-resolver honesty: `@docs` with no hits renders `(nothing found)`
  and no `--- Context ---` section.
- Assert telemetry: estimate is chars/4-based; percentage suppressed when the
  denominator is unknown; breakdown sums equal the displayed total.
- Assert pruning order for focus content and `locked` protection; assert the
  UI-visible pruned list is returned (parity between engine copy and model).
- Delete sort-priority and weight-label tests (`testComposeSortsByPriority…`,
  `testComposeEncodesWeightLabels`) — those mechanics are gone.

## 7. What this buys

- One honest mental object (an **Intent**) instead of a 48-cell abstraction
  that delivers 6 sentences.
- No duplication class of bugs (set semantics).
- Prompt text a model can actually act on — four short directives, ordered,
  with real context attached.
- Telemetry that could not silently lie, because its numerator and denominator
  are the real message and the real window.
- Presets that are curation of intent, not coordinates on an inert axis.
