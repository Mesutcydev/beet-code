# Context Compiler

`ContextCompiler` (Phase 12) turns a task description into a **budgeted,
inspectable `ContextPacket`**. Provider formatters render the packet; they
never query the index directly.

## Budget

`ContextBudget` derives from the model's actual window:

```
available = contextWindow − maxOutput − systemPrompt − conversation − safetyMargin
```

Allocation of `available`:

| Section | Share | Cap |
|---|---|---|
| capsule | min(800, available) | hard ceiling (spec §9) |
| knowledge | 25% of remainder | hard |
| graph (symbols + relationships) | 30% | hard |
| source snippets | 35% | hard |
| history (stale warnings) | 10% | hard |

A section can never borrow from another. The packet reports
`estimatedTokens` (~4 chars/token, the composer heuristic).

## Retrieval cascade

1. **Explicit anchors** — `@`-mentioned files/symbols from the composer.
2. **Exact symbol lookup** — identifier-shaped tokens (CamelCase /
   snake_case, ≥ 5 chars) in the task text.
3. **Graph neighborhood** — callers/callees of anchored symbols, depth 1.
4. **Lexical retrieval** — FTS5 symbol search (when a SearchIndex is wired).
5. **Source snippets** — bodies of anchored symbols (≤ 80 lines), run
   through the injection sanitizer (Phase 19).
6. **Knowledge** — fresh records first, ranked by task-term overlap;
   stale records surface as labeled warnings, capped at 3.

## Pins (Phase 18)

`pinnedPacks` reweight step 6: knowledge kinds in a pinned pack sort ahead
of unpinned records. The budget does not move — a pin reorders what fills
the packet, it never enlarges it.

## Inspectability

Every `ContextItem` carries `whyIncluded`, `confidence`, `freshness`, and
`estimatedTokens`. The inspector UI (Phase 17) and `lf intel context` render
exactly these fields — what you see is what the model gets.
