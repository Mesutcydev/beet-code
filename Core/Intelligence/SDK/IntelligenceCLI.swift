import Foundation

/// Phase 22 — command-line interface over WorkspaceIntelligence. Pure
/// routing + output through an injectable writer so tests capture stdout
/// without a process. The app binary early-exits into this when invoked
/// with the `intel` subcommand (see BeetCodeApp).
enum IntelligenceCLI {

    /// Runs a CLI invocation. `arguments` excludes the executable name and
    /// the leading `intel` token. Returns the process exit code.
    static func run(
        arguments: [String],
        write: (String) -> Void = { print($0) }
    ) async -> Int32 {
        guard let command = arguments.first else {
            write(usage)
            return 2
        }
        var rest = Array(arguments.dropFirst())

        // --workspace <path> (default: current directory)
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let flagIndex = rest.firstIndex(of: "--workspace"), rest.count > flagIndex + 1 {
            root = URL(fileURLWithPath: rest[flagIndex + 1])
            rest.removeSubrange(flagIndex...(flagIndex + 1))
        }
        let intel = WorkspaceIntelligence(workspaceRoot: root)

        do {
            switch command {
            case "index":
                let stats = try await intel.index()
                write("indexed: \(stats.parsed) parsed, \(stats.skippedUnsupported) unsupported, \(stats.durationMs) ms")
            case "update":
                let stats = try await intel.update()
                write("updated: +\(stats.added) ~\(stats.modified) -\(stats.deleted) →\(stats.renamed), \(stats.durationMs) ms")
            case "overview":
                write(try intel.overview())
            case "context":
                guard let task = rest.first else { write(usage); return 2 }
                let packet = try intel.context(for: task)
                let breakdown = IntelligenceInspectorBuilder.requestBreakdown(packet: packet)
                for row in breakdown.rows {
                    write("\(row.label): \(row.tokens) tokens")
                }
                write("Total: \(breakdown.total)")
            case "search":
                guard let query = rest.first else { write(usage); return 2 }
                let hits = try intel.searchSymbols(matching: query)
                if hits.isEmpty { write("no matches for '\(query)'") }
                for node in hits {
                    write("\(node.name) [\(node.symbolKind ?? "")] \(node.path ?? "?"):\(node.startLine ?? 0)")
                }
            case "impact":
                guard let name = rest.first else { write(usage); return 2 }
                write(try intel.impact(ofSymbol: name).rendered)
            case "verify":
                guard let type = rest.first, let a = rest.dropFirst().first
                else { write(usage); return 2 }
                let b = rest.dropFirst(2).first
                let verifier = try intel.verifier()
                let verdict: ClaimVerifier.Verdict
                switch type {
                case "symbol": verdict = try verifier.symbolExists(a)
                case "call":
                    guard let b else { write("verify call <caller> <callee>"); return 2 }
                    verdict = try verifier.callExists(caller: a, callee: b)
                case "test": verdict = try verifier.testCoversSymbol(a)
                case "file": verdict = try verifier.fileExists(a)
                default:
                    write("unknown claim type '\(type)' (symbol|call|test|file)")
                    return 2
                }
                switch verdict {
                case .verified(let evidence): write("VERIFIED: \(evidence)")
                case .false_(let reason, let suggestions):
                    write("FALSE: \(reason)")
                    if !suggestions.isEmpty {
                        write("suggestions: \(suggestions.joined(separator: ", "))")
                    }
                case .unverified(let reason): write("UNVERIFIED: \(reason)")
                }
            case "handoff":
                if let packet = try intel.handoff() {
                    write(packet.rendered())
                } else {
                    write("no working state for the current branch")
                }
            case "serve-mcp":
                // Blocking stdio loop — the MCP transport (Phase 21).
                try IntelligenceMCPServer(workspaceRoot: root).runStdio()
            default:
                write("unknown command '\(command)'\n\(usage)")
                return 2
            }
            return 0
        } catch {
            write("error: \(error.localizedDescription)")
            return 1
        }
    }

    static let usage = """
    beetcode intel <command> [--workspace <path>]

      index                    full (re)index of the workspace
      update                   incremental index update
      overview                 project capsule
      context <task>           compiled context breakdown for a task
      search <query>           lexical symbol search
      impact <symbol>          impact report for changing a symbol
      verify <type> <a> [b]    claim verification (symbol|call|test|file)
      handoff                  branch-scoped session handoff
      serve-mcp                MCP server on stdio (newline-delimited JSON-RPC)
    """
}
