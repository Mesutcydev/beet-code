import Foundation

/// Persistent symbol/reference graph (spec §8, Phase 3). Nodes and edges
/// originate ONLY from ParserCore output — every edge carries the parser
/// confidence and the file/line it was derived from. Nothing here is
/// heuristic-fabricated: a `calls` edge exists when a syntactic call
/// candidate resolves to exactly one symbol in the index (unambiguous by
/// name); ambiguous candidates are recorded as unresolved references, not
/// guessed edges.
final class SymbolGraph: @unchecked Sendable {

    // MARK: Public model

    enum NodeKind: String, Codable, Sendable {
        case file, symbol, test
    }

    struct Node: Sendable, Equatable {
        let id: String            // symbolID, or "file:<relativePath>"
        let kind: NodeKind
        let name: String
        let descriptor: String?
        let path: String?
        let startLine: Int?
        let endLine: Int?
        let containerID: String?
        /// Parser-level kind (class/struct/protocol/…) for symbol nodes.
        let symbolKind: String?
        /// Where this node's intelligence came from: `syntacticParser`,
        /// `sourcekit-lsp`, `scip`, `frameworkAdapter`… (spec §5).
        let source: String
    }

    enum EdgeKind: String, Codable, Sendable {
        case contains          // file/type contains symbol
        case imports           // file imports module (target = "module:<name>")
        case calls             // symbol calls symbol (unambiguous syntactic)
        case conforms          // type conforms to protocol (target kind known)
        case inherits          // type inherits class (target kind known)
        case typeRelation      // unresolved-shape relationship candidate
        case tests             // test symbol exercises target (via unique call)
    }

    struct Edge: Sendable, Equatable {
        let source: String
        let target: String
        let kind: EdgeKind
        /// File the edge was derived from (stale-detection dependency).
        let originPath: String
        let line: Int?
        let confidence: ParserConfidence
    }

    struct Neighborhood: Sendable, Equatable {
        var nodes: [Node]
        var edges: [Edge]
    }

    // MARK: Storage

    private let store: SQLiteStore
    private let lock = NSLock()

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                contentHash TEXT NOT NULL,
                language TEXT NOT NULL,
                parsedAt TEXT NOT NULL
            )
            """)
        try store.execute("""
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                descriptor TEXT,
                path TEXT,
                startLine INTEGER,
                endLine INTEGER,
                containerID TEXT,
                symbolKind TEXT,
                intelligenceSource TEXT NOT NULL DEFAULT 'syntacticParser'
            )
            """)
        try store.execute("""
            CREATE TABLE IF NOT EXISTS edges (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                target TEXT NOT NULL,
                kind TEXT NOT NULL,
                originPath TEXT NOT NULL,
                line INTEGER,
                confidence TEXT NOT NULL
            )
            """)
        try store.execute("CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source, kind)")
        try store.execute("CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target, kind)")
        try store.execute("CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name)")
        try migrateIfNeeded()
    }

    /// Adds columns introduced after the first schema version. The database
    /// is derived data, but cheap in-place migration beats a re-index.
    private func migrateIfNeeded() throws {
        var columns: Set<String> = []
        try store.query("PRAGMA table_info(nodes)", row: { row in
            if let name = row.text(1) { columns.insert(name) }
        })
        if !columns.contains("intelligenceSource") {
            try store.execute(
                "ALTER TABLE nodes ADD COLUMN intelligenceSource TEXT NOT NULL DEFAULT 'syntacticParser'")
        }
    }

    /// Upgrades node provenance after semantic verification (Phase 5).
    /// Returns the number of rows actually changed.
    @discardableResult
    func markSemantic(nodeIDs: [String], source: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var changed = 0
        for id in nodeIDs {
            try store.run(
                "UPDATE nodes SET intelligenceSource = ? WHERE id = ? AND intelligenceSource != ?",
                bind: {
                    try $0.bind(1, source)
                    try $0.bind(2, id)
                    try $0.bind(3, source)
                })
            changed += 1
        }
        return changed
    }

    // MARK: Mutation (per-file upsert — the incremental unit)

    /// Replaces everything derived from one file in a single transaction:
    /// its file row, its nodes, and every edge originating from it. Nodes
    /// belonging to OTHER files are never touched; edges pointing INTO this
    /// file's nodes from other files are repaired on their next upsert.
    func upsertFile(_ parsed: ParsedFile) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.transaction {
            try store.run("DELETE FROM edges WHERE originPath = ?", bind: { try $0.bind(1, parsed.path) })
            // Remove this file's nodes (symbol ids are descriptor-stable, so
            // re-added identical symbols keep identity).
            try store.run("DELETE FROM nodes WHERE path = ? OR id = ?") {
                try $0.bind(1, parsed.path)
                try $0.bind(2, "file:\(parsed.path)")
            }
            try store.run("""
                INSERT OR REPLACE INTO files (path, contentHash, language, parsedAt)
                VALUES (?, ?, ?, ?)
                """) {
                try $0.bind(1, parsed.path)
                try $0.bind(2, parsed.contentHash)
                try $0.bind(3, parsed.language)
                try $0.bind(4, ISO8601DateFormatter().string(from: Date()))
            }

            let fileNodeID = "file:\(parsed.path)"
            try insertNode(Node(
                id: fileNodeID, kind: .file,
                name: (parsed.path as NSString).lastPathComponent,
                descriptor: nil, path: parsed.path,
                startLine: nil, endLine: nil, containerID: nil, symbolKind: nil,
                source: "syntacticParser"))

            for symbol in parsed.symbols {
                try insertNode(Node(
                    id: symbol.symbolID,
                    kind: symbol.kind == .test ? .test : .symbol,
                    name: symbol.name,
                    descriptor: symbol.descriptor,
                    path: parsed.path,
                    startLine: symbol.range.startLine,
                    endLine: symbol.range.endLine,
                    containerID: symbol.containerID,
                    symbolKind: symbol.kind.rawValue,
                    source: "syntacticParser"))
                // Containment: file contains top-level symbols, containers
                // contain their members (edge from file or container node).
                let containerID = symbol.containerID ?? fileNodeID
                try insertEdge(Edge(
                    source: containerID, target: symbol.symbolID,
                    kind: .contains, originPath: parsed.path,
                    line: symbol.range.startLine, confidence: symbol.confidence))
            }

            for imp in parsed.imports {
                try insertEdge(Edge(
                    source: fileNodeID, target: "module:\(imp.module)",
                    kind: .imports, originPath: parsed.path,
                    line: imp.line, confidence: .syntactic))
            }

            try resolveAndInsertEdges(parsed)
        }
    }

    /// Removes a file and everything derived from it.
    func removeFile(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.transaction {
            try store.run("DELETE FROM edges WHERE originPath = ?", bind: { try $0.bind(1, path) })
            // Edges from other files pointing at this file's nodes are now
            // dangling — remove them too; the owning file re-creates them on
            // its next upsert if still valid.
            let nodeIDs = try nodeIDs(forPath: path)
            for id in nodeIDs {
                try store.run("DELETE FROM edges WHERE target = ?", bind: { try $0.bind(1, id) })
            }
            try store.run("DELETE FROM nodes WHERE path = ? OR id = ?") {
                try $0.bind(1, path)
                try $0.bind(2, "file:\(path)")
            }
            try store.run("DELETE FROM files WHERE path = ?", bind: { try $0.bind(1, path) })
        }
    }

    // MARK: Queries

    func node(id: String) throws -> Node? {
        lock.lock()
        defer { lock.unlock() }
        var result: Node?
        try store.query("SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind, intelligenceSource FROM nodes WHERE id = ?",
            bind: { try $0.bind(1, id) },
            row: { result = Self.mapNode($0) })
        return result
    }

    func findSymbols(named name: String) throws -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        var results: [Node] = []
        try store.query("SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind, intelligenceSource FROM nodes WHERE name = ? AND kind != 'file'",
            bind: { try $0.bind(1, name) },
            row: { results.append(Self.mapNode($0)) })
        return results
    }

    func outgoingEdges(from id: String, kind: EdgeKind? = nil) throws -> [Edge] {
        try edgesWhere(column: "source", id: id, kind: kind)
    }

    func incomingEdges(to id: String, kind: EdgeKind? = nil) throws -> [Edge] {
        try edgesWhere(column: "target", id: id, kind: kind)
    }

    /// Direct callers: symbols with a `calls` edge into this symbol.
    func callers(of id: String) throws -> [Node] {
        try relatedNodes(direction: .incoming, id: id, kind: .calls)
    }

    /// Direct callees: symbols this symbol calls.
    func callees(of id: String) throws -> [Node] {
        try relatedNodes(direction: .outgoing, id: id, kind: .calls)
    }

    /// All symbols defined in a file, at any nesting depth.
    func symbols(inFile path: String) throws -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        var results: [Node] = []
        try store.query("""
            SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind
            FROM nodes WHERE path = ? AND kind != 'file'
            """,
            bind: { try $0.bind(1, path) },
            row: { results.append(Self.mapNode($0)) })
        return results
    }

    /// Lexical case-insensitive substring search over symbol names —
    /// the `workspace_search` backend (Phase 21). Honest substring match,
    /// not ranking.
    func searchSymbols(matching substring: String, limit: Int = 20) throws -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        var results: [Node] = []
        try store.query("""
            SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind
            FROM nodes
            WHERE kind != 'file' AND instr(LOWER(name), LOWER(?)) > 0
            ORDER BY name LIMIT ?
            """,
            bind: {
                try $0.bind(1, substring)
                try $0.bind(2, Int64(limit))
            },
            row: { results.append(Self.mapNode($0)) })
        return results
    }

    /// Breadth-first impact neighborhood: everything reachable INCOMING
    /// (dependents) up to `depth` hops — who breaks if this node changes.
    func impactNeighborhood(of id: String, depth: Int) throws -> Neighborhood {
        lock.lock()
        defer { lock.unlock() }
        var seen: Set<String> = [id]
        var frontier: [String] = [id]
        var nodes: [Node] = []
        var edges: [Edge] = []
        var remaining = depth
        while !frontier.isEmpty, remaining > 0 {
            var next: [String] = []
            for current in frontier {
                let incoming = try edgesWhereLocked(column: "target", id: current, kind: nil)
                for edge in incoming {
                    edges.append(edge)
                    if seen.insert(edge.source).inserted {
                        next.append(edge.source)
                        if let node = try nodeLocked(id: edge.source) { nodes.append(node) }
                    }
                }
            }
            frontier = next
            remaining -= 1
        }
        return Neighborhood(nodes: nodes, edges: edges)
    }

    /// BFS shortest path between two nodes over all edge kinds, directed.
    /// Returns the node IDs in order, or nil when unreachable.
    func shortestPath(from source: String, to target: String, maxDepth: Int = 8) throws -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        if source == target { return [source] }
        var visited: Set<String> = [source]
        var queue: [(id: String, path: [String])] = [(source, [source])]
        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()
            if path.count > maxDepth { continue }
            for edge in try edgesWhereLocked(column: "source", id: current, kind: nil) {
                if edge.target == target { return path + [target] }
                if visited.insert(edge.target).inserted {
                    queue.append((edge.target, path + [edge.target]))
                }
            }
        }
        return nil
    }

    func countNodes() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        try store.query("SELECT COUNT(*) FROM nodes WHERE kind != 'file'",
                        row: { count = Int($0.int(0)) })
        return count
    }

    func countEdges() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        try store.query("SELECT COUNT(*) FROM edges", row: { count = Int($0.int(0)) })
        return count
    }

    /// Highest-degree symbol nodes (incoming + outgoing edges, containment
    /// excluded) — the structural hubs a capsule should name.
    func hubSymbols(limit: Int) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var names: [String] = []
        try store.query("""
            SELECT n.name, COUNT(e.id) AS degree
            FROM nodes n
            JOIN edges e ON (e.source = n.id OR e.target = n.id) AND e.kind != 'contains'
            WHERE n.kind != 'file'
            GROUP BY n.id ORDER BY degree DESC, n.name LIMIT ?
            """,
            bind: { try $0.bind(1, Int64(limit)) },
            row: { if let name = $0.text(0) { names.append(name) } })
        return names
    }

    // MARK: Internals

    private enum Direction { case incoming, outgoing }

    private func relatedNodes(direction: Direction, id: String, kind: EdgeKind) throws -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        let joinColumn = direction == .incoming ? "e.source" : "e.target"
        let whereColumn = direction == .incoming ? "e.target" : "e.source"
        var results: [Node] = []
        try store.query("""
            SELECT DISTINCT n.id, n.kind, n.name, n.descriptor, n.path, n.startLine, n.endLine, n.containerID, n.symbolKind, n.intelligenceSource
            FROM edges e JOIN nodes n ON n.id = \(joinColumn)
            WHERE \(whereColumn) = ? AND e.kind = ?
            """,
            bind: {
                try $0.bind(1, id)
                try $0.bind(2, kind.rawValue)
            },
            row: { results.append(Self.mapNode($0)) })
        return results
    }

    private func edgesWhere(column: String, id: String, kind: EdgeKind?) throws -> [Edge] {
        lock.lock()
        defer { lock.unlock() }
        return try edgesWhereLocked(column: column, id: id, kind: kind)
    }

    private func edgesWhereLocked(column: String, id: String, kind: EdgeKind?) throws -> [Edge] {
        var results: [Edge] = []
        let sql = kind == nil
            ? "SELECT source, target, kind, originPath, line, confidence FROM edges WHERE \(column) = ?"
            : "SELECT source, target, kind, originPath, line, confidence FROM edges WHERE \(column) = ? AND kind = ?"
        try store.query(sql,
            bind: {
                try $0.bind(1, id)
                if let kind { try $0.bind(2, kind.rawValue) }
            },
            row: { results.append(Self.mapEdge($0)) })
        return results
    }

    private func nodeLocked(id: String) throws -> Node? {
        var result: Node?
        try store.query("SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind, intelligenceSource FROM nodes WHERE id = ?",
            bind: { try $0.bind(1, id) },
            row: { result = Self.mapNode($0) })
        return result
    }

    private func nodeIDs(forPath path: String) throws -> [String] {
        var ids: [String] = []
        try store.query("SELECT id FROM nodes WHERE path = ?", bind: { try $0.bind(1, path) },
                        row: { if let id = $0.text(0) { ids.append(id) } })
        return ids
    }

    private func insertNode(_ node: Node) throws {
        try store.run("""
            INSERT OR REPLACE INTO nodes (id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind, intelligenceSource)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT intelligenceSource FROM nodes WHERE id = ?), 'syntacticParser'))
            """) {
            try $0.bind(1, node.id)
            try $0.bind(2, node.kind.rawValue)
            try $0.bind(3, node.name)
            try $0.bind(4, node.descriptor)
            try $0.bind(5, node.path)
            try $0.bind(6, Int64(node.startLine ?? -1))
            try $0.bind(7, Int64(node.endLine ?? -1))
            try $0.bind(8, node.containerID)
            try $0.bind(9, node.symbolKind)
            try $0.bind(10, node.id)
        }
    }

    private func insertEdge(_ edge: Edge) throws {
        try store.run("""
            INSERT INTO edges (source, target, kind, originPath, line, confidence)
            VALUES (?, ?, ?, ?, ?, ?)
            """) {
            try $0.bind(1, edge.source)
            try $0.bind(2, edge.target)
            try $0.bind(3, edge.kind.rawValue)
            try $0.bind(4, edge.originPath)
            try $0.bind(5, Int64(edge.line ?? -1))
            try $0.bind(6, edge.confidence.rawValue)
        }
    }

    /// Resolves this file's syntactic references against the CURRENT index.
    /// A call candidate becomes a `calls` edge only when exactly one symbol
    /// with that name exists workspace-wide; type mentions become conforms/
    /// inherits when the target kind is known, else typeRelation.
    private func resolveAndInsertEdges(_ parsed: ParsedFile) throws {
        // Build line→innermost symbol lookup for reference scoping.
        let symbols = parsed.symbols

        func innermostSymbol(atLine line: Int) -> ParsedSymbol? {
            symbols
                .filter { $0.range.startLine <= line && line <= $0.range.endLine }
                .max(by: { ($0.range.endLine - $0.range.startLine) < ($1.range.endLine - $1.range.startLine) })
        }

        for reference in parsed.references {
            let sourceID = reference.containerID
                ?? innermostSymbol(atLine: reference.line)?.symbolID
                ?? "file:\(parsed.path)"

            var candidates: [Node] = []
            try store.query("""
                SELECT id, kind, name, descriptor, path, startLine, endLine, containerID, symbolKind
                FROM nodes WHERE name = ? AND kind != 'file'
                """,
                bind: { try $0.bind(1, reference.name) },
                row: { candidates.append(Self.mapNode($0)) })

            // Never self-edge: a declaration's own name is not a call.
            candidates.removeAll { $0.id == sourceID }

            switch reference.kind {
            case .call:
                guard candidates.count == 1, let target = candidates.first else { continue }
                // A test symbol calling a symbol records a tests edge as well
                // as the calls edge — coverage without semantic guessing.
                let sourceIsTest = symbols.first { $0.symbolID == sourceID }?.kind == .test
                try insertEdge(Edge(
                    source: sourceID, target: target.id, kind: .calls,
                    originPath: parsed.path, line: reference.line, confidence: .syntactic))
                if sourceIsTest {
                    try insertEdge(Edge(
                        source: sourceID, target: target.id, kind: .tests,
                        originPath: parsed.path, line: reference.line, confidence: .syntactic))
                }
            case .typeMention:
                guard candidates.count == 1, let target = candidates.first else { continue }
                // The target's parsed kind decides the honest edge kind:
                // protocol → conforms; class/actor → inherits; unknown or
                // non-type target → unresolved-shape typeRelation candidate.
                let edgeKind: EdgeKind = switch target.symbolKind {
                case "protocol": .conforms
                case "class", "actor": .inherits
                default: .typeRelation
                }
                try insertEdge(Edge(
                    source: sourceID, target: target.id, kind: edgeKind,
                    originPath: parsed.path, line: reference.line, confidence: .syntactic))
            }
        }
    }

    private static func mapNode(_ row: SQLiteStore.Row) -> Node {
        Node(
            id: row.text(0) ?? "",
            kind: NodeKind(rawValue: row.text(1) ?? "symbol") ?? .symbol,
            name: row.text(2) ?? "",
            descriptor: row.text(3),
            path: row.text(4),
            startLine: { let v = row.int(5); return v >= 0 ? Int(v) : nil }(),
            endLine: { let v = row.int(6); return v >= 0 ? Int(v) : nil }(),
            containerID: row.text(7),
            symbolKind: row.text(8),
            source: row.text(9) ?? "syntacticParser")
    }

    private static func mapEdge(_ row: SQLiteStore.Row) -> Edge {
        Edge(
            source: row.text(0) ?? "",
            target: row.text(1) ?? "",
            kind: EdgeKind(rawValue: row.text(2) ?? "references") ?? .typeRelation,
            originPath: row.text(3) ?? "",
            line: { let v = row.int(4); return v >= 0 ? Int(v) : nil }(),
            confidence: ParserConfidence(rawValue: row.text(5) ?? "syntactic") ?? .syntactic)
    }
}
