# In-App Diagnostics — Spec

Status: implemented (v0.7) · Owner surface: `App/DiagnosticsCenter.swift`, `App/DiagnosticsPanelView.swift`

## 1. Goal

When something misbehaves — a model that stalls, a tool call that never
returns, an import that finds nothing — the answer must be inspectable
**inside the app**, not in Console.app. Diagnostics gives the user (and bug
reports) a chronological trail of what the app did: a **breadcrumb** per
notable event, a system snapshot, and one-click export.

Non-goals: crash reporting, analytics, anything leaving the Mac unprompted.
Diagnostics never contains message contents, file contents, or API keys —
metadata only (tool names, counts, durations, paths the user already sees).

## 2. Breadcrumbs

One breadcrumb = one notable event.

```swift
struct Breadcrumb: Identifiable {
    let id: UUID
    let date: Date
    let category: Category   // session · engine · tool · approval · import · system
    let level: Level         // info · warning · error
    let message: String      // short human sentence ("write_file approved")
    let detail: String?      // monospaced metadata (path, reason, counts)
}
```

| Category | Recorded events |
|---|---|
| `session` | task started/finished (reason), workspace switched, session restored, compaction |
| `engine` | model load start/ready/failed, unload, remote endpoint activation |
| `tool` | tool call started (name + summary), finished (✓/✗, output size), protocol errors, checkpoints created/failed |
| `approval` | approval requested / approved / declined, plan proposed / approved / revised, questions asked |
| `import` | chat-history import started/finished (counts) |
| `system` | app launch, memory pressure, thermal state changes |

Rules:

1. **Ring buffer, 500 entries**, newest last; oldest evicted silently.
2. **Append-only during a run** — breadcrumbs are a timeline, never edited.
3. **No content capture** — never message text, file bodies, tokens, or
   secrets. Lengths and names only.
4. Errors and warnings carry `level`; the panel badges them.

## 3. Panel

Docked side panel (same pattern as Browser/Simulator), opened from the
activity rail (stethoscope icon):

- **Header** — entry count, error/warning badge, Clear, Export…
- **System snapshot** — app version, macOS version, physical memory, thermal
  state, uptime. Static read at open, refresh on demand.
- **Filter pills** — All + one per category present, with counts (same pill
  language as the Imported tab).
- **Timeline** — reverse-chronological rows: time, category icon tinted by
  level, message, optional monospaced detail. Error rows get a danger wash.

## 4. Export

`Export…` writes a plain-text log (`beetcode-diagnostics-YYYYMMDD-HHmm.log`):

```
Beet Code diagnostics — exported 2026-08-19 18:20
App 0.7.0 · macOS 15.5 · 16 GB · thermal: nominal

18:01:12  session   task started — "audit for improvements…"
18:01:14  tool      ✓ list_directory (312 B)
18:01:20  approval  run_command approved (always: safe commands)
…
```

Intended to be attached to bug reports; contains no conversation content.

## 5. Instrumentation points

Single choke point: `AgentSessionController.handle(_ event:)` converts every
`AgentEvent` into breadcrumbs, so the Core loop needs no diagnostics
dependency. Engine/model events are recorded where the phase changes
(`AppState`), imports where the import runs (`SidebarView.runImport`), launch
in `BeetCodeApp`.

## 6. Future work

- Persist breadcrumbs across launches (bounded JSONL under Application
  Support, rotated at 1 MB).
- Performance breadcrumbs: tokens/s per generation, per-tool durations.
- Network pane for remote (BYOK) calls: status codes, latencies, retries.
