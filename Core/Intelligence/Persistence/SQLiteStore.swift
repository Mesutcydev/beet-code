import Foundation
import SQLite3

/// Minimal synchronous SQLite wrapper over the system library — no external
/// dependency, matching how ExternalHistoryImporter already uses SQLite3.
/// One database connection per instance; callers serialize access (the
/// owning stores are actors or lock-guarded). All statements are prepared
/// and finalized per call; bulk writes run inside explicit transactions.
final class SQLiteStore {

    enum StoreError: Error, LocalizedError {
        case openFailed(String)
        case executeFailed(String)
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let m): "SQLite open failed: \(m)"
            case .executeFailed(let m): "SQLite execute failed: \(m)"
            case .bindFailed(let m): "SQLite bind failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?

    /// Opens (creating if needed) the database at `url`. `:memory:` is
    /// supported for tests via `URL(fileURLWithPath: ":memory:")`? No —
    /// pass `inMemory: true` explicitly so test intent is unmistakable.
    init(url: URL, inMemory: Bool = false) throws {
        let path = inMemory ? ":memory:" : url.path
        if !inMemory {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        self.db = handle
        // WAL for concurrent readers during indexing writes; busy timeout so
        // a reader never hard-fails on a transient writer lock.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Schema / statement with no bound parameters and no result rows.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.executeFailed(message)
        }
    }

    /// Runs `body` inside a single transaction; rolls back on throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Prepared-statement query. `bind` receives 1-based binding helpers;
    /// `row` maps each result row. Rows are [String: SQLiteValue].
    func query(
        _ sql: String,
        bind: ((Statement) throws -> Void) = { _ in },
        row: (Row) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let wrapper = Statement(statement)
        try bind(wrapper)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                try row(Row(statement))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw StoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Convenience: run a statement with bindings, discarding any rows.
    func run(_ sql: String, bind: ((Statement) throws -> Void) = { _ in }) throws {
        try query(sql, bind: bind) { _ in }
    }

    // MARK: Value access

    final class Statement {
        private let statement: OpaquePointer
        init(_ statement: OpaquePointer) { self.statement = statement }

        func bind(_ index: Int, _ value: String?) throws {
            let status: Int32
            if let value {
                status = sqlite3_bind_text(statement, Int32(index), value, -1, SQLITE_TRANSIENT)
            } else {
                status = sqlite3_bind_null(statement, Int32(index))
            }
            guard status == SQLITE_OK else { throw StoreError.bindFailed("index \(index)") }
        }

        func bind(_ index: Int, _ value: Int64) throws {
            guard sqlite3_bind_int64(statement, Int32(index), value) == SQLITE_OK
            else { throw StoreError.bindFailed("index \(index)") }
        }

        func bind(_ index: Int, _ value: Double) throws {
            guard sqlite3_bind_double(statement, Int32(index), value) == SQLITE_OK
            else { throw StoreError.bindFailed("index \(index)") }
        }
    }

    struct Row {
        private let statement: OpaquePointer
        init(_ statement: OpaquePointer) { self.statement = statement }

        var count: Int { Int(sqlite3_column_count(statement)) }

        func text(_ index: Int) -> String? {
            guard let pointer = sqlite3_column_text(statement, Int32(index)) else { return nil }
            return String(cString: pointer)
        }

        func int(_ index: Int) -> Int64 {
            sqlite3_column_int64(statement, Int32(index))
        }

        func double(_ index: Int) -> Double {
            sqlite3_column_double(statement, Int32(index))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
