import Foundation

/// A point-in-time record of everything the intelligence layer knows about
/// the workspace's files. Immutable once captured; compared against the next
/// capture to drive incremental indexing (spec §26).
struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    let snapshotID: UUID
    let identity: WorkspaceIdentity
    /// Git state at capture time — branch/commit changes are detectable by
    /// comparing snapshots even when no file changed.
    let git: GitState?
    /// Files keyed by workspace-relative path. Directories are not recorded:
    /// they carry no content and are implied by file paths.
    let files: [String: SourceFileRecord]
    let createdAt: Date

    /// The change set between two snapshots of the same workspace.
    struct Delta: Sendable, Equatable {
        var added: [SourceFileRecord] = []
        var modified: [SourceFileRecord] = []
        var deleted: [SourceFileRecord] = []
        /// Content-identical delete+add pairs, reported as renames so
        /// symbol identity can be carried across the move.
        var renamed: [(from: SourceFileRecord, to: SourceFileRecord)] = []

        var isEmpty: Bool {
            added.isEmpty && modified.isEmpty && deleted.isEmpty && renamed.isEmpty
        }

        static func == (lhs: Delta, rhs: Delta) -> Bool {
            lhs.added == rhs.added
                && lhs.modified == rhs.modified
                && lhs.deleted == rhs.deleted
                && lhs.renamed.count == rhs.renamed.count
                && zip(lhs.renamed, rhs.renamed).allSatisfy { $0.from == $1.from && $0.to == $1.to }
        }
    }

    /// Computes what changed from `previous` to `self`. Rename detection is
    /// content-hash based: a deleted file and an added file with the same
    /// hash are the same content at a new path.
    func delta(from previous: WorkspaceSnapshot) -> Delta {
        var delta = Delta()

        for (path, record) in files {
            guard let old = previous.files[path] else {
                delta.added.append(record)
                continue
            }
            // Hash comparison when both sides hashed; otherwise size+mtime.
            if let newHash = record.contentHash, let oldHash = old.contentHash {
                if newHash != oldHash { delta.modified.append(record) }
            } else if record.sizeBytes != old.sizeBytes || record.modifiedAt != old.modifiedAt {
                delta.modified.append(record)
            }
        }
        for (path, record) in previous.files where files[path] == nil {
            delta.deleted.append(record)
        }

        // Pair deletes with identical-hash adds → renames. Deterministic
        // order keeps tests and downstream index updates reproducible.
        var remainingAdded = delta.added
        var remainingDeleted: [SourceFileRecord] = []
        for deleted in delta.deleted.sorted(by: { $0.relativePath < $1.relativePath }) {
            if let hash = deleted.contentHash,
               let matchIndex = remainingAdded.firstIndex(where: { $0.contentHash == hash }) {
                let added = remainingAdded.remove(at: matchIndex)
                delta.renamed.append((from: deleted, to: added))
            } else {
                remainingDeleted.append(deleted)
            }
        }
        delta.added = remainingAdded.sorted { $0.relativePath < $1.relativePath }
        delta.deleted = remainingDeleted
        delta.modified.sort { $0.relativePath < $1.relativePath }
        return delta
    }
}

/// Walks the workspace and captures a snapshot. Synchronous and
/// deterministic; callers run it off the main thread. Honors ignore rules,
/// never follows symlinks, and hashes file contents with SHA-256.
enum WorkspaceScanner {

    /// Hard caps so a hostile or pathological tree cannot stall capture.
    static let maxFiles = 200_000
    static let maxDepth = 32

    static func capture(identity: WorkspaceIdentity) -> WorkspaceSnapshot {
        let root = URL(fileURLWithPath: identity.canonicalPath, isDirectory: true)
        var files: [String: SourceFileRecord] = [:]
        var rules = IgnoreRules()
        // Root .gitignore first so it applies from the top.
        loadGitignore(into: &rules, directory: root, base: "")

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey])
        else {
            return WorkspaceSnapshot(
                snapshotID: UUID(), identity: identity, git: identity.git,
                files: [:], createdAt: Date())
        }

        var count = 0
        while let item = enumerator.nextObject() as? URL {
            if count >= Self.maxFiles { break }
            let values = try? item.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            let relative = relativePath(of: item, root: root)
            guard !relative.isEmpty else { continue }
            let depth = relative.split(separator: "/").count
            if depth > Self.maxDepth {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if isDirectory {
                let name = item.lastPathComponent
                if IgnoreRules.excludedDirectoryNames.contains(name)
                    || rules.isIgnored(relative, isDirectory: true) {
                    enumerator.skipDescendants()
                    continue
                }
                // Nested .gitignore scoped to this directory.
                loadGitignore(into: &rules, directory: item, base: relative)
                continue
            }

            if rules.isIgnored(relative, isDirectory: false) { continue }
            count += 1

            let size = Int64(values?.fileSize ?? 0)
            let hash: String? = size <= SourceFileRecord.maxHashableBytes
                ? ContentDigest.fileDigest(at: item)
                : nil
            files[relative] = SourceFileRecord(
                relativePath: relative,
                sizeBytes: size,
                contentHash: hash,
                modifiedAt: values?.contentModificationDate ?? .distantPast)
        }

        return WorkspaceSnapshot(
            snapshotID: UUID(),
            identity: identity,
            git: GitReader.refreshState(workspaceRoot: root),
            files: files,
            createdAt: Date())
    }

    private static func loadGitignore(into rules: inout IgnoreRules, directory: URL, base: String) {
        let url = directory.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        rules.addGitignore(contents: text, base: base)
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return "" }
        return String(url.path.dropFirst(rootPath.count))
    }
}

/// Persists snapshots per workspace under Application Support (never inside
/// the Git tree, spec §22). Only the latest snapshot plus a bounded history
/// are kept; the store is derived data and safe to delete.
final class WorkspaceSnapshotStore: @unchecked Sendable {

    static let shared = WorkspaceSnapshotStore()

    /// Test seam: redirect storage to a temporary directory.
    var overrideDirectory: URL?

    private let lock = NSLock()
    static let maxHistory = 8

    private func directory(for workspaceID: String) -> URL {
        let base: URL
        if let overrideDirectory {
            base = overrideDirectory
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeetCode/WorkspaceIntelligence", isDirectory: true)
        }
        return base
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// ISO-8601 with fractional seconds — freshness comparisons rely on
    /// exact Date round-trips, and the plain strategy truncates sub-second
    /// precision. ISO8601DateFormatter is thread-safe per its documentation;
    /// `nonisolated(unsafe)` satisfies the compiler's Sendable analysis.
    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        let dir = directory(for: snapshot.identity.workspaceID)
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Self.makeEncoder().encode(snapshot)
            // Latest pointer for cheap loads; history for delta across app restarts.
            try data.write(to: dir.appendingPathComponent("latest.json"), options: .atomic)
            try data.write(to: dir.appendingPathComponent("\(snapshot.snapshotID.uuidString).json"), options: .atomic)
            try pruneHistory(dir: dir, keep: Self.maxHistory)
        } catch {
            Log.intelligence.error("Snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadLatest(workspaceID: String) -> WorkspaceSnapshot? {
        let url = directory(for: workspaceID).appendingPathComponent("latest.json")
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    private func pruneHistory(dir: URL, keep: Int) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        let snapshots = contents
            .filter { $0.lastPathComponent != "latest.json" && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
        for stale in snapshots.dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
