import Foundation

/// Phase 21 — standalone MCP interface over the intelligence layer.
/// Deliberately small tool set (spec: "avoid dozens of overlapping tools"):
/// search folds into `workspace_search`/`knowledge_search` (kind filter),
/// decisions/pitfalls are knowledge kinds, not separate tools.
///
/// Transport-neutral core: `handle(method:params:)` speaks JSON-RPC shaped
/// dictionaries; `runStdio()` adapts it to MCP's newline-delimited stdio
/// transport. Every answer comes from the same deterministic stores the app
/// uses — the server invents nothing.
final class IntelligenceMCPServer {

    struct Tool: Sendable {
        let name: String
        let description: String
        /// JSON-schema-ish parameter documentation: name → "type: description".
        let parameters: [(String, String)]
        let required: [String]
    }

    static let protocolVersion = "2024-11-05"

    static let tools: [Tool] = [
        Tool(name: "workspace_overview",
             description: "Compact project capsule: languages, structure, hub symbols, branch.",
             parameters: [], required: []),
        Tool(name: "workspace_context",
             description: "Compile a budgeted context packet for a task description.",
             parameters: [("task", "string: the task text"),
                          ("budgetTokens", "int: workspace token budget (default 4000)")],
             required: ["task"]),
        Tool(name: "workspace_search",
             description: "Lexical search across symbols and knowledge.",
             parameters: [("query", "string"), ("limit", "int (default 10)")],
             required: ["query"]),
        Tool(name: "symbol_find",
             description: "Find symbols by exact name.",
             parameters: [("name", "string")], required: ["name"]),
        Tool(name: "symbol_callers",
             description: "Symbols with a calls edge into the named symbol.",
             parameters: [("name", "string")], required: ["name"]),
        Tool(name: "symbol_callees",
             description: "Symbols the named symbol calls.",
             parameters: [("name", "string")], required: ["name"]),
        Tool(name: "graph_neighbors",
             description: "Incoming and outgoing graph edges for a symbol.",
             parameters: [("name", "string")], required: ["name"]),
        Tool(name: "graph_impact",
             description: "Deterministic impact report for changing a symbol.",
             parameters: [("name", "string")], required: ["name"]),
        Tool(name: "knowledge_search",
             description: "Search durable knowledge records (kind filter covers decisions/pitfalls).",
             parameters: [("query", "string"),
                          ("kind", "string: optional knowledge kind filter")],
             required: ["query"]),
        Tool(name: "knowledge_propose",
             description: "Propose a durable knowledge record; passes the evidence pipeline.",
             parameters: [("kind", "string"), ("scope", "string"),
                          ("statement", "string"),
                          ("evidencePaths", "string array")],
             required: ["kind", "scope", "statement"]),
        Tool(name: "session_handoff",
             description: "Compile the branch-scoped session handoff packet.",
             parameters: [], required: []),
        Tool(name: "claim_verify",
             description: "Verify a structural claim against the live index.",
             parameters: [("type", "symbolExists|callExists|conformanceExists|dependencyExists|fileExists|testCoversSymbol"),
                          ("a", "string: symbol/caller/type/file"),
                          ("b", "string: callee/protocol/module (when needed)")],
             required: ["type", "a"]),
    ]

    // MARK: Wiring

    private let identity: WorkspaceIdentity
    private let graph: SymbolGraph
    private let knowledge: KnowledgeStore?
    private let entities: EntityStore?
    private let journal: InvalidationJournal?
    private let snapshotStore: WorkspaceSnapshotStore

    init(workspaceRoot: URL,
         snapshotStore: WorkspaceSnapshotStore = .shared) throws {
        let identity = WorkspaceIdentity.resolve(root: workspaceRoot)
        self.identity = identity
        self.snapshotStore = snapshotStore
        let graphURL = IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID)
        let metadataURL = IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID)
        graph = try SymbolGraph(store: SQLiteStore(url: graphURL))
        entities = try? EntityStore(store: SQLiteStore(url: graphURL))
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            knowledge = try? KnowledgeStore(store: SQLiteStore(url: metadataURL))
            journal = try? InvalidationJournal(store: SQLiteStore(url: metadataURL))
        } else {
            knowledge = nil
            journal = nil
        }
    }

    // MARK: JSON-RPC dispatch

    /// Handles one JSON-RPC request object. Returns the response payload
    /// (result or error), or nil for notifications.
    func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return Self.error(id: id, code: -32600, message: "invalid request")
        }
        switch method {
        case "initialize":
            return Self.result(id: id, payload: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "beetcode-intelligence", "version": "1.0.0"],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return Self.result(id: id, payload: [:])
        case "tools/list":
            return Self.result(id: id, payload: ["tools": Self.toolDescriptors()])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String
            else { return Self.error(id: id, code: -32602, message: "tools/call needs params.name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(name, arguments: arguments)
                return Self.result(id: id, payload: [
                    "content": [["type": "text", "text": text]],
                ])
            } catch ToolError.unknown(let tool) {
                return Self.error(id: id, code: -32601, message: "unknown tool: \(tool)")
            } catch ToolError.badArguments(let detail) {
                return Self.result(id: id, payload: [
                    "content": [["type": "text", "text": "error: \(detail)"]],
                    "isError": true,
                ])
            } catch {
                return Self.error(id: id, code: -32603, message: "\(error)")
            }
        default:
            return Self.error(id: id, code: -32601, message: "unknown method: \(method)")
        }
    }

    enum ToolError: Error {
        case unknown(String)
        case badArguments(String)
    }

    // MARK: Tools

    /// Executes a tool, returning the text payload. Arguments are the
    /// MCP `arguments` object.
    func callTool(_ name: String, arguments: [String: Any]) throws -> String {
        func require(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty
            else { throw ToolError.badArguments("missing or empty '\(key)'") }
            return value
        }

        switch name {
        case "workspace_overview":
            return try overview()
        case "workspace_context":
            let task = try require("task")
            let budgetTokens = arguments["budgetTokens"] as? Int ?? 4_000
            return try context(task: task, budgetTokens: budgetTokens)
        case "workspace_search":
            return try workspaceSearch(
                query: require("query"), limit: arguments["limit"] as? Int ?? 10)
        case "symbol_find":
            return try symbolFind(name: require("name"))
        case "symbol_callers":
            return try related(name: require("name"), direction: .callers)
        case "symbol_callees":
            return try related(name: require("name"), direction: .callees)
        case "graph_neighbors":
            return try neighbors(name: require("name"))
        case "graph_impact":
            return try ImpactAnalyzer(graph: graph, entities: entities)
                .impact(ofSymbol: require("name")).rendered
        case "knowledge_search":
            return try knowledgeSearch(
                query: require("query"), kind: arguments["kind"] as? String)
        case "knowledge_propose":
            return try knowledgePropose(arguments)
        case "session_handoff":
            return try handoff()
        case "claim_verify":
            return try claimVerify(
                type: require("type"), a: require("a"),
                b: arguments["b"] as? String)
        default:
            throw ToolError.unknown(name)
        }
    }

    // MARK: Tool implementations

    private func overview() throws -> String {
        guard let snapshot = snapshotStore.loadLatest(workspaceID: identity.workspaceID) else {
            return "workspace not indexed yet — no snapshot on disk"
        }
        let stale = (try? knowledge?.allRecords().filter { $0.freshness != .fresh }.count) ?? 0
        let capsule = try CapsuleGenerator.generate(
            identity: identity, snapshot: snapshot, graph: graph,
            staleKnowledgeCount: stale)
        return capsule.rendered()
    }

    private func context(task: String, budgetTokens: Int) throws -> String {
        let snapshot = snapshotStore.loadLatest(workspaceID: identity.workspaceID)
        let compiler = ContextCompiler(
            graph: graph, knowledge: knowledge,
            capsuleProvider: {
                if let snapshot {
                    return try CapsuleGenerator.generate(
                        identity: self.identity, snapshot: snapshot, graph: self.graph)
                }
                return ProjectCapsule(
                    projectName: self.identity.canonicalPath, languages: [],
                    structure: [], hubSymbols: [], branch: nil, commit: nil,
                    fileCount: 0, symbolCount: 0, edgeCount: 0,
                    snapshotID: UUID(), generatedAt: Date(), staleKnowledgeCount: 0)
            },
            sourceLoader: { path, start, end in
                guard let url = PathSafety.resolve(
                    root: URL(fileURLWithPath: self.identity.canonicalPath), relative: path),
                    let text = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                let lines = text.components(separatedBy: "\n")
                guard start >= 1, end <= lines.count else { return nil }
                return lines[(start - 1)..<end].joined(separator: "\n")
            })
        let packet = try compiler.compileContext(
            task: AgentTask(text: task),
            budget: ContextBudget(
                contextWindowTokens: budgetTokens + 6_000, maxOutputTokens: 4_000,
                systemPromptTokens: 1_000, conversationTokens: 500,
                safetyMarginTokens: 500))
        let breakdown = IntelligenceInspectorBuilder.requestBreakdown(packet: packet)
        var lines = [packet.capsule.rendered(), "", "CONTEXT (\(breakdown.total) tokens est.)"]
        for item in packet.items {
            lines.append("[\(item.section.rawValue)] \(item.text) — \(item.whyIncluded)")
        }
        for snippet in packet.sources {
            lines.append("[source] \(snippet.path):\(snippet.startLine)-\(snippet.endLine)")
        }
        return lines.joined(separator: "\n")
    }

    private func workspaceSearch(query: String, limit: Int) throws -> String {
        var lines: [String] = []
        let lowered = query.lowercased()
        var matched = 0
        for node in try graph.searchSymbols(matching: query, limit: limit) {
            lines.append("[symbol] \(node.name) [\(node.symbolKind ?? "")] \(node.path ?? "?"):\(node.startLine ?? 0)")
            matched += 1
        }
        if let knowledge {
            for record in try knowledge.allRecords() where matched < limit * 2 {
                if record.scope.lowercased().contains(lowered)
                    || record.statement.lowercased().contains(lowered) {
                    lines.append("[knowledge/\(record.kind.rawValue)] \(record.scope): \(record.statement)")
                    matched += 1
                }
            }
        }
        return lines.isEmpty ? "no matches for '\(query)'" : lines.joined(separator: "\n")
    }

    private func symbolFind(name: String) throws -> String {
        let nodes = try graph.findSymbols(named: name)
        guard !nodes.isEmpty else { return "no symbol named '\(name)'" }
        return nodes.map {
            "\($0.name) [\($0.symbolKind ?? $0.kind.rawValue)] \($0.path ?? "?"):\($0.startLine ?? 0)-\($0.endLine ?? 0)"
        }.joined(separator: "\n")
    }

    private enum Direction { case callers, callees }

    private func related(name: String, direction: Direction) throws -> String {
        let nodes = try graph.findSymbols(named: name)
        guard let node = nodes.first else { return "no symbol named '\(name)'" }
        let related = direction == .callers
            ? try graph.callers(of: node.id)
            : try graph.callees(of: node.id)
        guard !related.isEmpty else {
            return "no \(direction == .callers ? "callers" : "callees") of '\(name)'"
        }
        return related.map { "\($0.name) (\($0.path ?? "?"):\($0.startLine ?? 0))" }
            .joined(separator: "\n")
    }

    private func neighbors(name: String) throws -> String {
        let nodes = try graph.findSymbols(named: name)
        guard let node = nodes.first else { return "no symbol named '\(name)'" }
        var lines: [String] = []
        for edge in try graph.incomingEdges(to: node.id) {
            let other = try graph.node(id: edge.source)?.name ?? edge.source
            lines.append("← \(edge.kind.rawValue) from \(other) (\(edge.originPath):\(edge.line ?? 0))")
        }
        for edge in try graph.outgoingEdges(from: node.id) {
            let other = try graph.node(id: edge.target)?.name ?? edge.target
            lines.append("→ \(edge.kind.rawValue) to \(other) (\(edge.originPath):\(edge.line ?? 0))")
        }
        return lines.isEmpty ? "'\(name)' has no graph edges" : lines.joined(separator: "\n")
    }

    private func knowledgeSearch(query: String, kind: String?) throws -> String {
        guard let knowledge else { return "no knowledge store for this workspace" }
        let filter = kind.flatMap { KnowledgeKind(rawValue: $0) }
        let lowered = query.lowercased()
        let matches = try knowledge.records(kind: filter)
            .filter {
                lowered.isEmpty
                    || $0.scope.lowercased().contains(lowered)
                    || $0.statement.lowercased().contains(lowered)
            }
        guard !matches.isEmpty else { return "no knowledge matching '\(query)'" }
        return matches.map {
            "[\($0.kind.rawValue)/\($0.freshness.rawValue)] \($0.scope): \($0.statement)"
        }.joined(separator: "\n")
    }

    private func knowledgePropose(_ arguments: [String: Any]) throws -> String {
        guard let knowledge else { return "no knowledge store for this workspace" }
        guard let kindRaw = arguments["kind"] as? String,
              let kind = KnowledgeKind(rawValue: kindRaw)
        else { throw ToolError.badArguments("unknown kind '\(arguments["kind"] ?? "")'") }
        guard let scope = arguments["scope"] as? String,
              let statement = arguments["statement"] as? String
        else { throw ToolError.badArguments("scope and statement required") }
        let evidencePaths = arguments["evidencePaths"] as? [String] ?? []

        let pipeline = KnowledgePipeline(
            store: knowledge, graph: graph,
            hashProvider: { path in
                self.snapshotStore.loadLatest(workspaceID: self.identity.workspaceID)?
                    .files[path]?.contentHash
            },
            gitCommitProvider: {
                GitReader.read(workspaceRoot: URL(fileURLWithPath: self.identity.canonicalPath))?.commit
            })
        let result = try pipeline.propose(KnowledgeProposal(
            kind: kind, scope: scope, statement: statement,
            evidencePaths: evidencePaths, evidenceSymbols: [],
            branchScope: nil, origin: "agent"))
        switch result {
        case .committed(let id, let confidence):
            return "committed \(id) (confidence: \(confidence.rawValue))"
        case .duplicate(let existingID):
            return "duplicate of \(existingID)"
        case .rejected(let reason):
            return "rejected: \(reason)"
        case .conflict(let existingID):
            return "conflict with \(existingID) — held for resolution"
        }
    }

    private func handoff() throws -> String {
        guard FileManager.default.fileExists(
            atPath: IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID).path),
            let store = try? WorkingStateStore(store: SQLiteStore(
                url: IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID)))
        else { return "no session store for this workspace" }
        let branch = GitReader.read(
            workspaceRoot: URL(fileURLWithPath: identity.canonicalPath))?.branch ?? "main"
        guard let state = try store.latest(workspaceID: identity.workspaceID, branch: branch)
        else { return "no working state on branch '\(branch)'" }
        let relevant = (try? knowledge?.allRecords()) ?? []
        return HandoffCompiler.compileWithProgress(
            state: state, relevantKnowledge: relevant).rendered()
    }

    private func claimVerify(type: String, a: String, b: String?) throws -> String {
        let verifier = ClaimVerifier(graph: graph)
        let verdict: ClaimVerifier.Verdict
        switch type {
        case "symbolExists": verdict = try verifier.symbolExists(a)
        case "callExists":
            guard let b else { throw ToolError.badArguments("callExists needs b (callee)") }
            verdict = try verifier.callExists(caller: a, callee: b)
        case "conformanceExists":
            guard let b else { throw ToolError.badArguments("conformanceExists needs b (protocol)") }
            verdict = try verifier.conformanceExists(type: a, protocol: b)
        case "dependencyExists":
            guard let b else { throw ToolError.badArguments("dependencyExists needs b (module)") }
            verdict = try verifier.dependencyExists(file: a, imports: b)
        case "fileExists": verdict = try verifier.fileExists(a)
        case "testCoversSymbol": verdict = try verifier.testCoversSymbol(a)
        default: throw ToolError.badArguments("unknown claim type '\(type)'")
        }
        switch verdict {
        case .verified(let evidence): return "VERIFIED: \(evidence)"
        case .false_(let reason, let suggestions):
            return "FALSE: \(reason)"
                + (suggestions.isEmpty ? "" : "\nsuggestions: \(suggestions.joined(separator: ", "))")
        case .unverified(let reason): return "UNVERIFIED: \(reason)"
        }
    }

    // MARK: JSON-RPC helpers

    private static func toolDescriptors() -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: Any] = [:]
            for (name, spec) in tool.parameters {
                let parts = spec.split(separator: ":", maxSplits: 1)
                properties[name] = [
                    "type": parts.first.map { String($0).replacingOccurrences(
                        of: #" \(.*\)"#, with: "", options: .regularExpression) } ?? "string",
                    "description": parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "",
                ]
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.required,
                ] as [String: Any],
            ]
        }
    }

    private static func result(id: Any?, payload: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": payload]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }

    // MARK: Stdio transport

    /// MCP stdio loop: newline-delimited JSON-RPC on stdin/stdout. Blocks;
    /// call from a CLI entry point, never from the app UI.
    func runStdio() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = handle(request)
            else { continue }
            if let out = try? JSONSerialization.data(withJSONObject: response),
               let text = String(data: out, encoding: .utf8) {
                print(text)
                FileHandle.standardOutput.synchronizeFile()
            }
        }
    }
}
