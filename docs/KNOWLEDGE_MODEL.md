# Knowledge Model

Durable project knowledge (Phases 8/9) — what the workspace *means*, as
opposed to what it *contains*.

## Record

```
KnowledgeRecord
  id          kn_ + 10 hex of sha256(kind|scope|normalized statement)
  kind        architecture | logic | feature | capability | security | data
              | interface | runtime | testing | convention | decision
              | pitfall | procedure
  scope       what the fact is about (module / feature / subsystem)
  statement   the fact itself
  confidence  verified | inferred | userProvided | historical
  freshness   fresh | potentiallyStale | stale | invalid
  evidence    [Evidence] — path, optional symbol, lines, content hash,
              git commit, capture time
  branchScope nil = project-wide
```

## The write gate

Agents **never** write `KnowledgeStore` directly. Every fact passes through
`KnowledgePipeline.propose`:

1. Statement sanity (minimum substance).
2. **Secret scan** — secret-shaped content is rejected.
3. **Injection scan** (Phase 19) — instruction-like content is rejected.
4. Deduplication (kind + scope + normalized statement).
5. **Evidence attachment** — the pipeline attaches *current* content hashes;
   agents cannot self-certify evidence.
6. **Graph verification** — cited symbols must exist in the live index.
7. **Conflict detection** — a materially different statement in the same
   kind+scope is held as `conflict`, never silently overwritten.
8. Confidence ceiling by origin: agent claims without evidence are
   rejected; `verified` requires evidence and symbol verification;
   user-provided and imported records are labeled as such.

Result: `committed | duplicate | rejected(reason) | conflict(existingID)`.

## Freshness

Evidence carries the content hash of its source at commit time.
`reevaluateFreshness(currentHashes:)` compares against the live index:

- hash unchanged → `fresh`
- file changed → `stale`
- file deleted → `invalid`

The context compiler includes only `fresh` records as fact; stale records
appear as labeled warnings. Trust order in the packet: decisions and
pitfalls ahead of general knowledge.

## Storage

`metadata.sqlite` (WAL) under Application Support, per workspace. Derived
data: deleting it loses knowledge, not code.
