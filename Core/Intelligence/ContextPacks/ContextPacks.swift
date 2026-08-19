import Foundation

/// Phase 18 — user-pinnable logical context packs. A pin changes RETRIEVAL
/// WEIGHTING inside the same hard token budget (spec: "must not force
/// indiscriminate prompt dumping") — pinned knowledge sorts ahead of
/// unpinned, and the packet still truncates at the knowledge cap.
enum ContextPack: String, Codable, Sendable, CaseIterable {
    case architecture, logic, features, data, security
    case capabilities, runtime, testing, decisions, pitfalls

    /// Knowledge kinds this pack boosts.
    var knowledgeKinds: Set<KnowledgeKind> {
        switch self {
        case .architecture: [.architecture]
        case .logic: [.logic]
        case .features: [.feature]
        case .data: [.data]
        case .security: [.security]
        case .capabilities: [.capability]
        case .runtime: [.runtime]
        case .testing: [.testing]
        case .decisions: [.decision]
        case .pitfalls: [.pitfall]
        }
    }
}

/// Pin persistence (spec Phase 18: session-scoped and optional
/// workspace-level preferences). Lives in metadata.sqlite alongside the
/// other derived stores. A workspace pin applies to every session in the
/// workspace; a session pin applies only to its own session.
final class ContextPackPinStore {

    enum Scope: String, Sendable {
        case session, workspace
    }

    private let store: SQLiteStore
    private let lock = NSLock()

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS context_pack_pins (
                pack TEXT NOT NULL,
                scope TEXT NOT NULL,
                workspaceID TEXT NOT NULL,
                sessionID TEXT NOT NULL,
                createdAt TEXT NOT NULL,
                PRIMARY KEY (pack, scope, workspaceID, sessionID)
            )
            """)
    }

    func pin(_ pack: ContextPack, scope: Scope, workspaceID: String,
             sessionID: UUID? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.run("""
            INSERT OR REPLACE INTO context_pack_pins
                (pack, scope, workspaceID, sessionID, createdAt)
            VALUES (?, ?, ?, ?, ?)
            """) {
            try $0.bind(1, pack.rawValue)
            try $0.bind(2, scope.rawValue)
            try $0.bind(3, workspaceID)
            // Empty string stands in for NULL so the composite primary key
            // deduplicates workspace-scope pins (SQLite treats NULLs as distinct).
            try $0.bind(4, sessionID?.uuidString ?? "")
            try $0.bind(5, WorkspaceSnapshotStore.dateFormatter.string(from: Date()))
        }
    }

    func unpin(_ pack: ContextPack, scope: Scope, workspaceID: String,
               sessionID: UUID? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.run("""
            DELETE FROM context_pack_pins
            WHERE pack = ? AND scope = ? AND workspaceID = ? AND sessionID = ?
            """) {
            try $0.bind(1, pack.rawValue)
            try $0.bind(2, scope.rawValue)
            try $0.bind(3, workspaceID)
            try $0.bind(4, sessionID?.uuidString ?? "")
        }
    }

    /// Effective pins for a session: workspace-level pins always apply,
    /// session-level pins only to their own session.
    func pinnedPacks(workspaceID: String, sessionID: UUID?) throws -> Set<ContextPack> {
        lock.lock()
        defer { lock.unlock() }
        var packs: Set<ContextPack> = []
        try store.query("""
            SELECT pack FROM context_pack_pins
            WHERE workspaceID = ? AND (sessionID = '' OR sessionID = ?)
            """,
            bind: {
                try $0.bind(1, workspaceID)
                try $0.bind(2, sessionID?.uuidString ?? "")
            },
            row: { row in
                if let raw = row.text(0), let pack = ContextPack(rawValue: raw) {
                    packs.insert(pack)
                }
            })
        return packs
    }
}
