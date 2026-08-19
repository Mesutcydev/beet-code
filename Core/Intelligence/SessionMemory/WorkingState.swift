import Foundation

/// Temporary, branch-scoped session state (spec §4.C, Phase 10). This is
/// NOT durable project knowledge: it lives per (workspace, branch, session),
/// never feeds the knowledge store directly, and switching branches never
/// leaks it into unrelated work (spec §19).
struct WorkingState: Sendable, Equatable {
    let sessionID: UUID
    let workspaceID: String
    /// Branch this state belongs to — the isolation boundary.
    let branch: String

    var objective: String = ""
    var plan: [String] = []
    var touchedFiles: [String] = []
    var hypotheses: [String] = []
    var openQuestions: [String] = []
    var failingTests: [String] = []
    var passingTests = 0
    var totalTests = 0
    /// Short structural diff summary ("3 files +38 -12"), computed by the
    /// caller from git — never narrative.
    var diffDigest: String = ""
    var updatedAt: Date = Date()
}

/// SQLite-backed working-state store. Session deletion removes exactly one
/// row set — project-level intelligence is in other tables entirely.
final class WorkingStateStore {

    private let store: SQLiteStore
    private let lock = NSLock()

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS working_state (
                sessionID TEXT NOT NULL,
                workspaceID TEXT NOT NULL,
                branch TEXT NOT NULL,
                objective TEXT NOT NULL,
                plan TEXT NOT NULL,
                touchedFiles TEXT NOT NULL,
                hypotheses TEXT NOT NULL,
                openQuestions TEXT NOT NULL,
                failingTests TEXT NOT NULL,
                passingTests INTEGER NOT NULL,
                totalTests INTEGER NOT NULL,
                diffDigest TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                PRIMARY KEY (workspaceID, branch, sessionID)
            )
            """)
    }

    func save(_ state: WorkingState) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        try store.run("""
            INSERT OR REPLACE INTO working_state
            (sessionID, workspaceID, branch, objective, plan, touchedFiles,
             hypotheses, openQuestions, failingTests, passingTests, totalTests,
             diffDigest, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) {
            try $0.bind(1, state.sessionID.uuidString)
            try $0.bind(2, state.workspaceID)
            try $0.bind(3, state.branch)
            try $0.bind(4, state.objective)
            try $0.bind(5, String(decoding: try encoder.encode(state.plan), as: UTF8.self))
            try $0.bind(6, String(decoding: try encoder.encode(state.touchedFiles), as: UTF8.self))
            try $0.bind(7, String(decoding: try encoder.encode(state.hypotheses), as: UTF8.self))
            try $0.bind(8, String(decoding: try encoder.encode(state.openQuestions), as: UTF8.self))
            try $0.bind(9, String(decoding: try encoder.encode(state.failingTests), as: UTF8.self))
            try $0.bind(10, Int64(state.passingTests))
            try $0.bind(11, Int64(state.totalTests))
            try $0.bind(12, state.diffDigest)
            try $0.bind(13, WorkspaceSnapshotStore.dateFormatter.string(from: state.updatedAt))
        }
    }

    func load(workspaceID: String, branch: String, sessionID: UUID) throws -> WorkingState? {
        lock.lock()
        defer { lock.unlock() }
        var result: WorkingState?
        try store.query("""
            SELECT objective, plan, touchedFiles, hypotheses, openQuestions,
                   failingTests, passingTests, totalTests, diffDigest, updatedAt
            FROM working_state
            WHERE workspaceID = ? AND branch = ? AND sessionID = ?
            """,
            bind: {
                try $0.bind(1, workspaceID)
                try $0.bind(2, branch)
                try $0.bind(3, sessionID.uuidString)
            },
            row: { row in
                let decoder = JSONDecoder()
                func list(_ index: Int) -> [String] {
                    guard let text = row.text(index), let data = text.data(using: .utf8) else { return [] }
                    return (try? decoder.decode([String].self, from: data)) ?? []
                }
                var state = WorkingState(
                    sessionID: sessionID, workspaceID: workspaceID, branch: branch)
                state.objective = row.text(0) ?? ""
                state.plan = list(1)
                state.touchedFiles = list(2)
                state.hypotheses = list(3)
                state.openQuestions = list(4)
                state.failingTests = list(5)
                state.passingTests = Int(row.int(6))
                state.totalTests = Int(row.int(7))
                state.diffDigest = row.text(8) ?? ""
                state.updatedAt = WorkspaceSnapshotStore.dateFormatter
                    .date(from: row.text(9) ?? "") ?? .distantPast
                result = state
            })
        return result
    }

    /// Most recent session state for a branch — used on workspace reopen.
    func latest(workspaceID: String, branch: String) throws -> WorkingState? {
        // Lock only for the ID lookup; load() takes the lock itself and
        // NSLock is not recursive.
        let sessionID: String? = try {
            lock.lock()
            defer { lock.unlock() }
            var found: String?
            try store.query("""
                SELECT sessionID FROM working_state
                WHERE workspaceID = ? AND branch = ?
                ORDER BY updatedAt DESC LIMIT 1
                """,
                bind: {
                    try $0.bind(1, workspaceID)
                    try $0.bind(2, branch)
                },
                row: { found = $0.text(0) })
            return found
        }()
        guard let idText = sessionID, let id = UUID(uuidString: idText) else { return nil }
        return try load(workspaceID: workspaceID, branch: branch, sessionID: id)
    }

    func delete(workspaceID: String, branch: String, sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.run("""
            DELETE FROM working_state
            WHERE workspaceID = ? AND branch = ? AND sessionID = ?
            """) {
            try $0.bind(1, workspaceID)
            try $0.bind(2, branch)
            try $0.bind(3, sessionID.uuidString)
        }
    }
}
