# Beet Code Cache Architecture (ForgeCache)

Adopted design: EPOCH/ForgeCache hybrid from the caching review —
Exact-prefix MLX reuse + content-addressed repository intelligence +
dependency-fingerprinted tool results + durable task capsules +
pressure-aware hot/warm/cold eviction.

One rule governs everything:

> Deleting the entire cache directory must never delete the project,
> conversation, models, pending edits, or agent progress.

## Current state (audit)

Already correct (keep):

- AgentLoop is append-only: generate() sends only history[sentTurnCount...]
  and appends assistant/tool turns; nothing rewrites earlier messages.
- MLXEngine holds ONE ChatSession per load; reset() only at compaction
  boundaries (compactIfNeeded) — a deliberate, single cache miss.
- PromptBuilder sorts tools by name — canonical tool ordering.
- SessionRecord (messages + checkpoints) is durable in Application
  Support, encrypted; ContextCompactor preserves assistant/tool pairing.
- MemoryAdvisor + ThermalMonitor + MemoryPressureCoordinator exist; the
  pressure reactions will be extended to evict the new caches.
- Workspace is realpath-canonical; RepoIndex is bounded + task-ranked.

Missing (this phase adds):

- No content-addressed repo summary cache (every build re-reads file heads).
- No tool-result (action) cache with fingerprints and policies.
- No durable agent task capsule (plan/decisions/diagnostics separate from chat).
- No workspace digest usable in action fingerprints.
- No explicit KV/RAM budget calculation for caches.

## Prompt regions (epochal prompt)

P0 — global stable prefix: system instructions, editing protocol, tool
definitions (sorted by stable tool ID — name is the ID today).
P1 — frozen workspace epoch: repo map, AGENTS.md content, memory section.
P2 — append-only task stream: user request, assistant turns, tool results,
workspace deltas.

AgentLoop already implements this shape: the system prompt is built once
per task (init), the workspace index once per task, and P2 grows by append.
Compaction rebuilds P1 + a new session = one intentional cache miss per epoch.

## Disk layout

    ~/Library/Application Support/BeetCode/
        Sessions/            (durable, encrypted)
        AgentTasks/          (task capsules, durable)
        Models/              (user-managed assets)

    ~/Library/Caches/BeetCode/EPOCH/
        ProjectIndexes/      (per-workspace summary cache, disposable)
        PromptSnapshots/     (reserved for MLX prompt-cache snapshots)
        ToolResults/         (reserved for disk action cache)
        Retrieval/           (reserved for vector hot set)
        RenderedUI/          (reserved for UI caches)

Deleting Caches/BeetCode/EPOCH must always be safe.

## Tool cache policies

- never: writes, commands, git mutations, network, permissions.
- contentAddressed: read_file (file digest + canonical args).
- shortLived(TTL): list_directory (2s), search (5s) — safe coalescing
  without pretending to know the whole workspace.
- workspaceEpoch: reserved for build diagnostics once the workspace digest
  is wired (not in this phase — builds still run through the real toolchain).

## Invalidation matrix (implemented this phase)

| Change | Invalidate |
|---|---|
| File content changes | read_file cache entry for that path; summary cache entry (size+mtime mismatch) |
| Tool arguments change | action key changes (canonical JSON hash) |
| Workspace root path changes | workspace component of the fingerprint |
| TTL expires | shortLived entries dropped on lookup |
| Memory warning | evictAll: in-memory action cache + summary hot set (disk summaries survive) |
| Cache directory deleted | next access recomputes from source — never an error |

## Budget governor (phase 1)

RuntimeBudget.calculate(availableBytes:) implements the EPOCH formula:
20% reserve (min 1.28 GB), then 60% of headroom to KV (cap 768 MB) and
20% to hot objects (cap 256 MB); constrained floor of 128 MB KV / 64 MB hot
when headroom is under 512 MB. MemoryAdvisor stays the authority for model
admission; this governor only budgets derived caches.

## Implementation order

1. (done, kept) append-only loop + single ChatSession + sorted tools.
2. (this phase) content digest, repo summary cache + workspace digest,
   action cache with policies, task capsules, budget calculator, pressure
   wiring, tests.
3. (next) FSEvents-driven dirty marking, disk action cache, MLX prompt
   snapshot allowlist with restore-equivalence tests.
4. (later) embeddings behind idle/thermal gates, build action cache only
   after full input fingerprinting.

## Release gate (cache-specific tests)

- Deleting every cache loses no project, conversation, or capsule data.
- Tool definitions identical regardless of registration order.
- Editing one file invalidates only that file's cached results.
- Cached tool result rejected after any hashed input changes.
- Memory warning releases disposable hot caches, keeps durable state.
- Capsule round-trips through disk and survives cache deletion.
