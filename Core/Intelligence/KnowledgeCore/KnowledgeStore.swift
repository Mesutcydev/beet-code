import Foundation

/// Provenance for a durable fact (spec §6). The contentHash pins the fact to
/// an exact file state; when the file's hash changes, dependent knowledge
/// goes stale deterministically (spec §7) — no LLM involved.
struct Evidence: Codable, Sendable, Equatable {
    let path: String
    let symbolID: String?
    let startLine: Int?
    let endLine: Int?
    let contentHash: String
    let gitCommit: String?
    let capturedAt: Date
}

enum KnowledgeConfidence: String, Codable, Sendable, CaseIterable {
    case deterministic
    case verified
    case inferred
    case userProvided
    case historical
}

enum FreshnessState: String, Codable, Sendable {
    case fresh
    case potentiallyStale
    case stale
    case invalid
}

enum KnowledgeKind: String, Codable, Sendable, CaseIterable {
    case architecture, logic, feature, capability, security, data
    case interface, runtime, testing, convention, decision, pitfall, procedure
}

/// A durable project-knowledge record (spec §4.B). Agents never write these
/// directly — they arrive via the proposal pipeline (Phase 9).
struct KnowledgeRecord: Sendable, Equatable {
    let id: String
    let kind: KnowledgeKind
    /// What the fact is about: a module, feature, or subsystem name.
    let scope: String
    let statement: String
    let confidence: KnowledgeConfidence
    var freshness: FreshnessState
    let evidence: [Evidence]
    /// Branch this record is scoped to; nil = project-wide.
    let branchScope: String?
    let createdAt: Date
    var updatedAt: Date
}

/// Persistent knowledge store (knowledge.sqlite). Synchronous SQLite under
/// a lock, like the other intelligence stores.
final class KnowledgeStore {

    private let store: SQLiteStore
    private let lock = NSLock()

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS knowledge (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                scope TEXT NOT NULL,
                statement TEXT NOT NULL,
                confidence TEXT NOT NULL,
                freshness TEXT NOT NULL,
                branchScope TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """)
        try store.execute("""
            CREATE TABLE IF NOT EXISTS evidence (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                knowledgeID TEXT NOT NULL,
                path TEXT NOT NULL,
                symbolID TEXT,
                startLine INTEGER,
                endLine INTEGER,
                contentHash TEXT NOT NULL,
                gitCommit TEXT,
                capturedAt TEXT NOT NULL
            )
            """)
        try store.execute("CREATE INDEX IF NOT EXISTS idx_evidence_path ON evidence(path)")
        try store.execute("CREATE INDEX IF NOT EXISTS idx_knowledge_scope ON knowledge(scope, kind)")
    }

    // MARK: Writes

    func insert(_ record: KnowledgeRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.transaction {
            try store.run("""
                INSERT OR REPLACE INTO knowledge
                (id, kind, scope, statement, confidence, freshness, branchScope, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) {
                try $0.bind(1, record.id)
                try $0.bind(2, record.kind.rawValue)
                try $0.bind(3, record.scope)
                try $0.bind(4, record.statement)
                try $0.bind(5, record.confidence.rawValue)
                try $0.bind(6, record.freshness.rawValue)
                try $0.bind(7, record.branchScope)
                try $0.bind(8, WorkspaceSnapshotStore.dateFormatter.string(from: record.createdAt))
                try $0.bind(9, WorkspaceSnapshotStore.dateFormatter.string(from: record.updatedAt))
            }
            try store.run("DELETE FROM evidence WHERE knowledgeID = ?",
                          bind: { try $0.bind(1, record.id) })
            for item in record.evidence {
                try store.run("""
                    INSERT INTO evidence
                    (knowledgeID, path, symbolID, startLine, endLine, contentHash, gitCommit, capturedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """) {
                    try $0.bind(1, record.id)
                    try $0.bind(2, item.path)
                    try $0.bind(3, item.symbolID)
                    try $0.bind(4, Int64(item.startLine ?? -1))
                    try $0.bind(5, Int64(item.endLine ?? -1))
                    try $0.bind(6, item.contentHash)
                    try $0.bind(7, item.gitCommit)
                    try $0.bind(8, WorkspaceSnapshotStore.dateFormatter.string(from: item.capturedAt))
                }
            }
        }
    }

    func updateFreshness(id: String, freshness: FreshnessState) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.run("""
            UPDATE knowledge SET freshness = ?, updatedAt = ? WHERE id = ?
            """) {
            try $0.bind(1, freshness.rawValue)
            try $0.bind(2, WorkspaceSnapshotStore.dateFormatter.string(from: Date()))
            try $0.bind(3, id)
        }
    }

    // MARK: Reads

    func record(id: String) throws -> KnowledgeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try recordLocked(id: id)
    }

    func allRecords() throws -> [KnowledgeRecord] {
        lock.lock()
        defer { lock.unlock() }
        var ids: [String] = []
        try store.query("SELECT id FROM knowledge ORDER BY createdAt", row: {
            if let id = $0.text(0) { ids.append(id) }
        })
        return try ids.compactMap { try recordLocked(id: $0) }
    }

    func records(kind: KnowledgeKind? = nil, scope: String? = nil,
                 freshness: FreshnessState? = nil) throws -> [KnowledgeRecord] {
        try allRecords().filter { record in
            (kind == nil || record.kind == kind)
                && (scope == nil || record.scope == scope)
                && (freshness == nil || record.freshness == freshness)
        }
    }

    /// Deterministic staleness evaluation (spec §7). `currentHashes` maps
    /// path → current content hash (nil = file deleted). Every record whose
    /// evidence pins a CHANGED file becomes stale; deleted evidence makes it
    /// invalid. Files not in the map are treated as unchanged.
    func reevaluateFreshness(currentHashes: [String: String?]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var changed = 0
        for record in try allRecordsLocked() {
            var worst: FreshnessState = .fresh
            for item in record.evidence {
                guard let current = currentHashes[item.path] else { continue }
                switch current {
                case .none:
                    worst = .invalid
                case .some(let hash) where hash != item.contentHash:
                    if worst != .invalid { worst = .stale }
                default:
                    break
                }
            }
            if worst != .fresh && record.freshness != worst {
                try store.run("UPDATE knowledge SET freshness = ?, updatedAt = ? WHERE id = ?") {
                    try $0.bind(1, worst.rawValue)
                    try $0.bind(2, WorkspaceSnapshotStore.dateFormatter.string(from: Date()))
                    try $0.bind(3, record.id)
                }
                changed += 1
            }
        }
        return changed
    }

    // MARK: Internals

    private func allRecordsLocked() throws -> [KnowledgeRecord] {
        var ids: [String] = []
        try store.query("SELECT id FROM knowledge ORDER BY createdAt", row: {
            if let id = $0.text(0) { ids.append(id) }
        })
        return try ids.compactMap { try recordLocked(id: $0) }
    }

    private func recordLocked(id: String) throws -> KnowledgeRecord? {
        var found: (KnowledgeKind, String, String, KnowledgeConfidence, FreshnessState, String?, Date, Date)?
        try store.query("""
            SELECT kind, scope, statement, confidence, freshness, branchScope, createdAt, updatedAt
            FROM knowledge WHERE id = ?
            """,
            bind: { try $0.bind(1, id) },
            row: { row in
                let formatter = WorkspaceSnapshotStore.dateFormatter
                found = (
                    KnowledgeKind(rawValue: row.text(0) ?? "") ?? .logic,
                    row.text(1) ?? "",
                    row.text(2) ?? "",
                    KnowledgeConfidence(rawValue: row.text(3) ?? "") ?? .inferred,
                    FreshnessState(rawValue: row.text(4) ?? "") ?? .potentiallyStale,
                    row.text(5),
                    formatter.date(from: row.text(6) ?? "") ?? .distantPast,
                    formatter.date(from: row.text(7) ?? "") ?? .distantPast)
            })
        guard let f = found else { return nil }

        var evidence: [Evidence] = []
        try store.query("""
            SELECT path, symbolID, startLine, endLine, contentHash, gitCommit, capturedAt
            FROM evidence WHERE knowledgeID = ?
            """,
            bind: { try $0.bind(1, id) },
            row: { row in
                evidence.append(Evidence(
                    path: row.text(0) ?? "",
                    symbolID: row.text(1),
                    startLine: { let v = row.int(2); return v >= 0 ? Int(v) : nil }(),
                    endLine: { let v = row.int(3); return v >= 0 ? Int(v) : nil }(),
                    contentHash: row.text(4) ?? "",
                    gitCommit: row.text(5),
                    capturedAt: WorkspaceSnapshotStore.dateFormatter.date(from: row.text(6) ?? "") ?? .distantPast))
            })

        return KnowledgeRecord(
            id: id, kind: f.0, scope: f.1, statement: f.2,
            confidence: f.3, freshness: f.4, evidence: evidence,
            branchScope: f.5, createdAt: f.6, updatedAt: f.7)
    }
}
