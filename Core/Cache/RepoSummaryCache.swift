import Foundation

/// Disk-backed summary cache for the repo indexer. Keyed by
/// (path | byte size | nanosecond mtime) — the fast-path identity from the
/// caching review. In-memory hot map on top; disk survives relaunch. The
/// entire directory lives under Caches and must be safely deletable: a miss
/// simply recomputes from source.
final class RepoSummaryCache: @unchecked Sendable {

    static let shared = RepoSummaryCache()

    /// Test seam: redirect disk storage to a temporary directory.
    var overrideDirectory: URL?

    private let lock = NSLock()
    private var memory: [String: String?] = [:]
    private var hits = 0
    private var misses = 0

    private var directory: URL {
        if let overrideDirectory { return overrideDirectory }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("BeetCode/EPOCH/ProjectIndexes", isDirectory: true)
    }

    private func diskURL(for key: String) -> URL {
        directory.appendingPathComponent(ContentDigest.sha256Hex(key) + ".summary")
    }

    /// Returns the cached summary (nil = known to have none), computing via
    /// `compute` on a miss. Compute runs OUTSIDE the lock; a duplicate
    /// computation under contention is benign.
    func summary(key: String, compute: () -> String?) -> String? {
        lock.lock()
        if let cached = memory[key] {
            hits += 1
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = diskURL(for: key)
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            let value = text == "∅" ? nil : text
            lock.lock()
            memory[key] = value
            hits += 1
            lock.unlock()
            return value
        }

        lock.lock()
        misses += 1
        lock.unlock()
        let value = compute()
        lock.lock()
        if memory[key] == nil {
            memory[key] = value
        }
        lock.unlock()

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = value ?? "∅"
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
        return value
    }

    /// Pressure response: drop the hot map only; disk summaries survive.
    func clearMemory() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
    }

    var stats: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses)
    }
}
