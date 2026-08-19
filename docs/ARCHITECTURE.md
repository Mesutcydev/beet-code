# Architecture — Workspace Intelligence

`Core/Intelligence/` is a UI-independent, deterministic workspace
intelligence layer. Every fact it serves comes from a parse, a store, or a
git invocation — never from an LLM's memory.

## Data flow

```
workspace files
   │  WorkspaceScanner (Phase 1: identity, git state, .gitignore, hashes)
   ▼
WorkspaceSnapshot ──delta──▶ IndexEngine (Phase 4)
                                │ parse (ParserCore, Phase 2)
                                │ detect (EntityCore, Phase 14)
                                ▼
                     ┌──────────────────────┐
                     │ graph.sqlite         │  nodes / edges / entities
                     │ metadata.sqlite      │  invalidations / knowledge /
                     │                      │  working state / pins
                     └──────────────────────┘
                                │
   SemanticEnricher (Phase 5, SourceKit-LSP) upgrades provenance labels only
                                ▼
        ┌──────────────┬───────────────┬───────────────┐
        ▼              ▼               ▼               ▼
  ContextCompiler  ImpactAnalyzer  ClaimVerifier   KnowledgePipeline
  (Phase 12)       (Phase 15)      (Phase 13)      (Phase 8/9)
        │                                              ▲
        ▼                                              │ proposals only
  ContextPacket ──▶ agent prompt                       │
        ▲                                              │
  ContextPack pins (Phase 18) reweight retrieval       │
                                                       │
  Consumers: App inspector UI (17) · MCP server (21) · │
  SDK facade + CLI (22) ───────────────────────────────┘
```

## Modules

| Module | Phase | Responsibility |
|---|---|---|
| WorkspaceCore | 1 | Identity (move-safe `wks_` IDs), git state, scanning, snapshots/deltas |
| ParserCore | 2 | Language adapters; Swift parser (syntactic confidence) |
| SymbolGraph | 3 | SQLite nodes/edges; unique-name edge resolution only |
| Persistence | 3 | SQLiteStore (WAL, transactions) |
| IndexCore | 4 | Full/incremental indexing, invalidation journal, FSEvents watcher |
| SemanticCore | 5 | SourceKit-LSP enrichment; provenance upgrades, never invention |
| SearchCore | 6 | FTS5 index, BM25, rank fusion |
| CapsuleCore | 7 | Project capsule (≤800 tokens, deterministic) |
| KnowledgeCore | 8/9 | Durable knowledge + evidence + write-gate pipeline |
| SessionMemory | 10/11 | Branch-scoped working state, handoff packets |
| ContextCompiler | 12 | Retrieval cascade + hard token budgets → ContextPacket |
| VerificationCore | 13 | Structural claim verification with evidence |
| EntityCore | 14 | Framework entities; SwiftUI/SwiftData adapter |
| ImpactCore | 15 | Graph-derived impact reports |
| GitIntelligence | 16 | Optional history source, policy-gated |
| Inspector | 17 | Inspector model (UI reads it verbatim) |
| ContextPacks | 18 | Session/workspace pins → retrieval weighting |
| SecurityCore | 19 | Injection sanitizer, path safety, binary detection |
| MCPServer | 21 | 12-tool MCP interface (stdio JSON-RPC) |
| SDK | 22 | `WorkspaceIntelligence` facade + `lf intel` CLI |

## Invariants

- **Determinism**: same workspace state → same packet. No LLM in retrieval.
- **Provenance**: every node/edge/record carries its intelligence source;
  `syntactic` and `semantic` are never blended.
- **Derived data**: everything under `Application Support/BeetCode/
  WorkspaceIntelligence` can be deleted; re-indexing rebuilds it.
- **Confinement**: file access resolves through realpath containment;
  ignored files are never read.
