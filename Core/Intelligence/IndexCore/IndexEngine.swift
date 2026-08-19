import Foundation

/// Per-workspace on-disk layout (spec §22). Everything lives under
/// Application Support — never inside the Git tree — and every directory is
/// derived data: deleting it costs a re-index, nothing more.
enum IntelligenceStoreLayout {

    /// Test seam shared by all intelligence stores.
    nonisolated(unsafe) static var overrideRoot: URL?

    static func root(for workspaceID: String) -> URL {
        let base: URL
        if let overrideRoot {
            base = overrideRoot
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeetCode/WorkspaceIntelligence", isDirectory: true)
        }
        return base.appendingPathComponent(workspaceID, isDirectory: true)
    }

    static func graphDatabase(for workspaceID: String) -> URL {
        root(for: workspaceID).appendingPathComponent("graph.sqlite")
    }

    static func metadataDatabase(for workspaceID: String) -> URL {
        root(for: workspaceID).appendingPathComponent("metadata.sqlite")
    }
}

/// Records which source units changed and when, so derived intelligence
/// (knowledge, capsules — later phases) can go stale deterministically
/// without any LLM noticing anything (spec §7).
final class InvalidationJournal {

    enum ChangeKind: String, Sendable {
        case added, modified, deleted, renamed
    }

    struct Entry: Sendable, Equatable {
        let path: String
        let kind: ChangeKind
        let oldHash: String?
        let newHash: String?
        let at: Date
    }

    private let store: SQLiteStore

    init(store: SQLiteStore) throws {
        self.store = store
        try store.execute("""
            CREATE TABLE IF NOT EXISTS invalidations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                oldHash TEXT,
                newHash TEXT,
                at TEXT NOT NULL
            )
            """)
        try store.execute("CREATE INDEX IF NOT EXISTS idx_inval_path ON invalidations(path)")
    }

    func record(_ entry: Entry) throws {
        try store.run("""
            INSERT INTO invalidations (path, kind, oldHash, newHash, at)
            VALUES (?, ?, ?, ?, ?)
            """) {
            try $0.bind(1, entry.path)
            try $0.bind(2, entry.kind.rawValue)
            try $0.bind(3, entry.oldHash)
            try $0.bind(4, entry.newHash)
            try $0.bind(5, WorkspaceSnapshotStore.dateFormatter.string(from: entry.at))
        }
    }

    /// All recorded changes touching `path`, oldest first.
    func entries(forPath path: String) throws -> [Entry] {
        var results: [Entry] = []
        try store.query("""
            SELECT path, kind, oldHash, newHash, at FROM invalidations
            WHERE path = ? ORDER BY id
            """,
            bind: { try $0.bind(1, path) },
            row: { row in
                results.append(Entry(
                    path: row.text(0) ?? "",
                    kind: ChangeKind(rawValue: row.text(1) ?? "modified") ?? .modified,
                    oldHash: row.text(2),
                    newHash: row.text(3),
                    at: WorkspaceSnapshotStore.dateFormatter.date(from: row.text(4) ?? "") ?? .distantPast))
            })
        return results
    }

    /// Distinct paths changed since `date` — the staleness input for
    /// derived-knowledge freshness evaluation.
    func changedPaths(since date: Date) throws -> [String] {
        var results: [String] = []
        try store.query(
            "SELECT DISTINCT path FROM invalidations WHERE at > ?",
            bind: { try $0.bind(1, WorkspaceSnapshotStore.dateFormatter.string(from: date)) },
            row: { if let path = $0.text(0) { results.append(path) } })
        return results
    }
}

/// The indexing pipeline (spec §25/§26). Owns: snapshot capture → delta →
/// parse → graph upsert → invalidation journaling. All operations are
/// incremental after the first full pass; nothing is ever rebuilt wholesale
/// unless the caller explicitly asks for a full re-index.
actor IndexEngine {

    struct UpdateStats: Sendable, Equatable {
        var added = 0
        var modified = 0
        var deleted = 0
        var renamed = 0
        var parsed = 0
        var skippedUnsupported = 0
        var durationMs: Int = 0
    }

    let identity: WorkspaceIdentity
    private let graph: SymbolGraph
    private let journal: InvalidationJournal
    private let snapshotStore: WorkspaceSnapshotStore
    private let entityStore: EntityStore?

    /// - Parameters:
    ///   - identity: resolved workspace identity (Phase 1).
    ///   - graph: the workspace's graph (Phase 3).
    ///   - journal: invalidation journal (metadata.sqlite).
    ///   - entityStore: framework-entity store (Phase 14); nil disables
    ///     entity detection.
    init(identity: WorkspaceIdentity, graph: SymbolGraph, journal: InvalidationJournal,
         snapshotStore: WorkspaceSnapshotStore = .shared,
         entityStore: EntityStore? = nil) {
        self.identity = identity
        self.graph = graph
        self.journal = journal
        self.snapshotStore = snapshotStore
        self.entityStore = entityStore
    }

    /// Convenience wiring for the standard per-workspace layout.
    static func makeDefault(identity: WorkspaceIdentity) throws -> IndexEngine {
        let graph = try SymbolGraph(store: SQLiteStore(
            url: IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID)))
        let journal = try InvalidationJournal(store: SQLiteStore(
            url: IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID)))
        let entities = try EntityStore(store: SQLiteStore(
            url: IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID)))
        return IndexEngine(identity: identity, graph: graph, journal: journal,
                           entityStore: entities)
    }

    var graphHandle: SymbolGraph { graph }
    var entityStoreHandle: EntityStore? { entityStore }

    /// First-open flow (spec §25): snapshot, parse everything supported,
    /// build the graph, persist the snapshot.
    @discardableResult
    func fullIndex() throws -> UpdateStats {
        let started = Date()
        let snapshot = WorkspaceScanner.capture(identity: identity)
        var stats = UpdateStats()
        for record in snapshot.files.values.sorted(by: { $0.relativePath < $1.relativePath }) {
            try indexFile(record, stats: &stats)
            try journal.record(InvalidationJournal.Entry(
                path: record.relativePath, kind: .added,
                oldHash: nil, newHash: record.contentHash, at: Date()))
            stats.added += 1
        }
        snapshotStore.save(snapshot)
        stats.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        return stats
    }

    /// Subsequent-open flow (spec §26): capture, diff against the last
    /// persisted snapshot, apply ONLY the delta.
    @discardableResult
    func incrementalUpdate() throws -> UpdateStats {
        let started = Date()
        let current = WorkspaceScanner.capture(identity: identity)
        guard let previous = snapshotStore.loadLatest(workspaceID: identity.workspaceID) else {
            // No baseline: an incremental pass over nothing would silently
            // skip the whole tree — do a full index instead.
            return try fullIndex()
        }
        let delta = current.delta(from: previous)
        var stats = UpdateStats()

        for record in delta.deleted {
            try graph.removeFile(path: record.relativePath)
            try entityStore?.removeFile(path: record.relativePath)
            try journal.record(.init(path: record.relativePath, kind: .deleted,
                                     oldHash: record.contentHash, newHash: nil, at: Date()))
            stats.deleted += 1
        }
        // Renames: remove old path, index new path. Symbol descriptors embed
        // the path, so identity honestly changes — the journal preserves the
        // rename relationship for knowledge freshness.
        for rename in delta.renamed {
            try graph.removeFile(path: rename.from.relativePath)
            try entityStore?.removeFile(path: rename.from.relativePath)
            try indexFile(rename.to, stats: &stats)
            try journal.record(.init(path: rename.from.relativePath, kind: .renamed,
                                     oldHash: rename.from.contentHash, newHash: nil, at: Date()))
            try journal.record(.init(path: rename.to.relativePath, kind: .renamed,
                                     oldHash: nil, newHash: rename.to.contentHash, at: Date()))
            stats.renamed += 1
        }
        for record in delta.added {
            try indexFile(record, stats: &stats)
            try journal.record(.init(path: record.relativePath, kind: .added,
                                     oldHash: nil, newHash: record.contentHash, at: Date()))
            stats.added += 1
        }
        for record in delta.modified {
            try indexFile(record, stats: &stats)
            try journal.record(.init(path: record.relativePath, kind: .modified,
                                     oldHash: previous.files[record.relativePath]?.contentHash,
                                     newHash: record.contentHash, at: Date()))
            stats.modified += 1
        }

        snapshotStore.save(current)
        stats.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        return stats
    }

    // MARK: Internals

    private func indexFile(_ record: SourceFileRecord, stats: inout UpdateStats) throws {
        guard let hash = record.contentHash else { return } // over hash budget: tracked, unparsed
        let url = URL(fileURLWithPath: identity.canonicalPath)
            .appendingPathComponent(record.relativePath)
        guard let data = try? Data(contentsOf: url),
              !BinaryContentDetector.isLikelyBinary(data),
              let text = String(data: data, encoding: .utf8)
        else { return } // unreadable/binary: tracked in the snapshot, not parsed
        let source = SourceFile(path: record.relativePath, content: text, contentHash: hash)
        if let parsed = ParserRegistry.parse(file: source) {
            try graph.upsertFile(parsed)
            stats.parsed += 1
            // Framework entities ride the same lifecycle as the graph
            // (Phase 14): detect from parse output + content, replace per file.
            if let entityStore {
                try entityStore.replaceEntities(
                    forFile: record.relativePath,
                    entities: EntityAdapterRegistry.detect(file: source, parsed: parsed))
            }
        } else {
            stats.skippedUnsupported += 1
            // Content-only entity detection (plists, manifests) still runs.
            if let entityStore {
                try entityStore.replaceEntities(
                    forFile: record.relativePath,
                    entities: EntityAdapterRegistry.detect(file: source, parsed: nil))
            }
        }
    }
}
