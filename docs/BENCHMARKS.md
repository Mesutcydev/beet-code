# Benchmarks — Workspace Intelligence

Measured by `PerformanceScaleTests` (Phase 20) against synthetic repositories
generated deterministically at test time. Hardware: Apple Silicon macOS.
Numbers below are from the 2026-08-19 run; re-run the suite for current data.

## Scale matrix

| Repo shape | Files | Full index | Incremental (1% touched) | Symbol query | Caller query | Impact (depth 2) | Context compile | Store size |
|---|---|---|---|---|---|---|---|---|
| small | 20 | 26 ms | 16 ms | 36 µs | 36 µs | 51 µs | <1 ms | 1.3 MB |
| medium | 200 | 189 ms | 32 ms | 30 µs | 37 µs | 66 µs | <1 ms | 5.6 MB |
| large | 1,000 | 1,763 ms | 178 ms | 61 µs | 43 µs | 84 µs | <1 ms | 5.6 MB |
| monorepo (6 packages) | 180 | 233 ms | 92 ms | 46 µs | 41 µs | 55 µs | <1 ms | 3.7 MB |

## Shape-specific findings

- **Branch-heavy** (12 branches): indexing unaffected — 453 ms full index;
  identity stays stable across checkouts (Phase 1 identity design).
- **Generated files**: 100 files behind `.gitignore` skipped entirely —
  88 ms index of the 10 real files; ignored content is never read.
- **Multi-language**: 20 Swift files parsed, 40 Python/JS files honestly
  recorded as `skippedUnsupported` (30 ms). No adapter, no guessing.

## Real-world smoke

Indexing BeetCode itself (177 Swift files + 29 unsupported): **1.56 s**
full index via `lf intel index`.

## Notes

- Incremental updates are ~10× faster than full index at 1% churn and scale
  with the delta, not the tree.
- Query latencies are flat with repo size (indexed SQLite lookups).
- Memory usage is not asserted in tests; stores are SQLite (paged) and
  parse working sets are per-file. A pathological-regression guard
  (order-of-magnitude) is asserted instead of wall-clock budgets.
