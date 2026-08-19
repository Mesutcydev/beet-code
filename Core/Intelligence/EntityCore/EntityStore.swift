import Foundation

/// Persistent store for framework-adapter detections (Phase 14). Lives in
/// the same database file as the symbol graph (WAL allows concurrent
/// connections) and shares the graph's lifecycle: entities are replaced
/// per-file on re-index and removed when the file disappears.
final class EntityStore: @unchecked Sendable {

    private let store: SQLiteStore
    private let lock = NSLock()

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                line INTEGER,
                symbolID TEXT,
                attributes TEXT NOT NULL,
                source TEXT NOT NULL
            )
            """)
        try store.execute("CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind)")
        try store.execute("CREATE INDEX IF NOT EXISTS idx_entities_path ON entities(path)")
    }

    /// Atomically replaces everything detected from `path`. Re-indexing a
    /// file can never leave stale entities behind.
    func replaceEntities(forFile path: String, entities: [SemanticEntity]) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.transaction {
            try store.run("DELETE FROM entities WHERE path = ?") { try $0.bind(1, path) }
            for entity in entities {
                let attributes = String(
                    decoding: (try? JSONEncoder().encode(entity.attributes)) ?? Data("{}".utf8),
                    as: UTF8.self)
                try store.run("""
                    INSERT OR REPLACE INTO entities
                        (id, kind, name, path, line, symbolID, attributes, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """) {
                    try $0.bind(1, entity.id)
                    try $0.bind(2, entity.kind.rawValue)
                    try $0.bind(3, entity.name)
                    try $0.bind(4, entity.path)
                    if let line = entity.line {
                        try $0.bind(5, Int64(line))
                    } else {
                        try $0.bind(5, nil as String?)
                    }
                    try $0.bind(6, entity.symbolID)
                    try $0.bind(7, attributes)
                    try $0.bind(8, entity.source)
                }
            }
        }
    }

    func removeFile(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.run("DELETE FROM entities WHERE path = ?") { try $0.bind(1, path) }
    }

    func entities(forPath path: String) throws -> [SemanticEntity] {
        try select("SELECT id, kind, name, path, line, symbolID, attributes, source FROM entities WHERE path = ? ORDER BY kind, name") {
            try $0.bind(1, path)
        }
    }

    func entities(ofKind kind: EntityKind) throws -> [SemanticEntity] {
        try select("SELECT id, kind, name, path, line, symbolID, attributes, source FROM entities WHERE kind = ? ORDER BY name") {
            try $0.bind(1, kind.rawValue)
        }
    }

    func allEntities() throws -> [SemanticEntity] {
        try select("SELECT id, kind, name, path, line, symbolID, attributes, source FROM entities ORDER BY kind, name")
    }

    func count() throws -> Int {
        var total = 0
        lock.lock()
        defer { lock.unlock() }
        try store.query("SELECT COUNT(*) FROM entities", row: { total = Int($0.int(0)) })
        return total
    }

    // MARK: Features

    /// Top-level path components that are containers, not features.
    private static let genericRoots: Set<String> = [
        "sources", "source", "src", "app", "core", "packages",
    ]

    /// Derived feature name for a workspace-relative path. Features are
    /// directory-level groupings (spec Phase 14) — derived, not declared:
    /// `Sources/Auth/Login.swift` → `Auth`; `Networking/Client.swift` →
    /// `Networking`; loose root files → `(root)`.
    static func featureName(forPath path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1, let first = components.first else { return "(root)" }
        if genericRoots.contains(first.lowercased()) {
            return components[1]
        }
        return first
    }

    /// All entities grouped by derived feature name.
    func features() throws -> [String: [SemanticEntity]] {
        var grouped: [String: [SemanticEntity]] = [:]
        for entity in try allEntities() {
            grouped[Self.featureName(forPath: entity.path), default: []].append(entity)
        }
        return grouped
    }

    // MARK: Internals

    private func select(
        _ sql: String,
        bind: ((SQLiteStore.Statement) throws -> Void) = { _ in }
    ) throws -> [SemanticEntity] {
        lock.lock()
        defer { lock.unlock() }
        var results: [SemanticEntity] = []
        try store.query(sql, bind: bind) { row in
            let attributesJSON = row.text(6) ?? "{}"
            let attributes = (try? JSONDecoder().decode(
                [String: String].self, from: Data(attributesJSON.utf8))) ?? [:]
            results.append(SemanticEntity(
                kind: EntityKind(rawValue: row.text(1) ?? "") ?? .capability,
                name: row.text(2) ?? "",
                path: row.text(3) ?? "",
                line: row.text(4).flatMap { Int($0) },
                symbolID: row.text(5),
                attributes: attributes,
                source: row.text(7) ?? "unknown"))
        }
        return results
    }
}
