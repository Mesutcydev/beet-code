# SDK & CLI

The intelligence layer is UI-independent. Two programmatic surfaces:

## Swift facade — `WorkspaceIntelligence`

```swift
let intel = WorkspaceIntelligence(workspaceRoot: url)

// Indexing
try await intel.index()                 // full (first) index
try await intel.update()                // incremental, delta-driven

// Reads
try intel.overview()                    // project capsule (≤800 tokens)
try intel.context(for: "fix refresh",   // budgeted ContextPacket
                  budgetTokens: 4_000, sessionID: session)
try intel.searchSymbols(matching: "auth")
try intel.impact(ofSymbol: "refreshToken")   // ImpactReport

// Knowledge lifecycle (always through the pipeline)
try intel.proposeKnowledge(kind: .decision, scope: "Auth",
    statement: "tokens live in memory only",
    evidencePaths: ["Sources/Auth/AuthService.swift"])

// Session handoff (branch-scoped)
try intel.handoff()

// Claim verification
let verifier = try intel.verifier()
try verifier.symbolExists("refreshToken")
try verifier.callExists(caller: "resume", callee: "refreshToken")
```

Stores open per call against the standard per-workspace layout
(`Application Support/BeetCode/WorkspaceIntelligence/<wks_id>/`), so the
facade is cheap to construct and safe to hold.

## CLI — `lf intel`

The `lf` binary (`BeetCodeCLI` target) exposes:

```sh
lf intel index    [--workspace <path>]   # full index
lf intel update   [--workspace <path>]   # incremental update
lf intel overview [--workspace <path>]   # capsule
lf intel context "task"                  # packet breakdown
lf intel search <query>                  # symbol substring search
lf intel impact <symbol>                 # impact report
lf intel verify <symbol|call|test|file> <a> [b]
lf intel handoff                         # branch-scoped handoff
lf intel serve-mcp                       # MCP server on stdio
```

The app binary also early-exits into the same CLI:
`BeetCode.app/Contents/MacOS/BeetCode intel <command>`.

## MCP server (Phase 21)

`lf intel serve-mcp` speaks newline-delimited JSON-RPC (MCP stdio). Twelve
tools, intentionally: `workspace_overview`, `workspace_context`,
`workspace_search`, `symbol_find`, `symbol_callers`, `symbol_callees`,
`graph_neighbors`, `graph_impact`, `knowledge_search`, `knowledge_propose`,
`session_handoff`, `claim_verify`. Decisions/pitfalls are
`knowledge_search` kind filters, not separate tools.
