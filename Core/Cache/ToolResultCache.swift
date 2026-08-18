import Foundation

/// How a tool's results may be cached. Every tool opts in explicitly; the
/// default is never. Mutating, network, and secret-bearing tools stay `.never`
/// forever.
enum ToolCachePolicy: Sendable, Equatable {
    case never
    case contentAddressed
    case workspaceEpoch
    case shortLived(TimeInterval)

    var ttl: TimeInterval? {
        if case .shortLived(let interval) = self { return interval }
        return nil
    }
}

/// The full identity of one tool invocation: tool + version + canonical
/// arguments + workspace + the hashed identities of the inputs it depends on.
/// Identical fingerprints may share results; any changed component misses.
struct ActionFingerprint: Hashable, Sendable {
    let toolID: String
    let toolVersion: String
    let canonicalArgumentsHash: String
    let workspaceSnapshotHash: String
    let inputContentHashes: [String]
}

struct ToolCacheStats: Sendable, Equatable {
    let hits: Int
    let misses: Int
    let stores: Int
    let evictions: Int
}

/// In-memory action cache with LRU eviction and a hard byte budget. Results
/// are only ever stored for successful executions; failed results are never
/// cached (a transient failure must not masquerade as a reusable answer).
actor ToolResultCache {

    static let shared = ToolResultCache()

    private struct Entry {
        let result: ToolExecutor.Outcome
        let expiresAt: Date?
        var lastAccess: Date
        let byteSize: Int
    }

    private var entries: [ActionFingerprint: Entry] = [:]
    private var totalBytes = 0
    private let maxBytes: Int
    private let maxEntries: Int
    private var hits = 0
    private var misses = 0
    private var stores = 0
    private var evictions = 0

    init(maxBytes: Int = 8 * 1024 * 1024, maxEntries: Int = 512) {
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
    }

    func result(for key: ActionFingerprint, ttl: TimeInterval?) -> ToolExecutor.Outcome? {
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        if let expiresAt = entry.expiresAt, Date() >= expiresAt {
            entries[key] = nil
            totalBytes -= entry.byteSize
            misses += 1
            return nil
        }
        entry.lastAccess = Date()
        entries[key] = entry
        hits += 1
        return entry.result
    }

    func store(_ result: ToolExecutor.Outcome, for key: ActionFingerprint, ttl: TimeInterval?) {
        let byteSize = result.output.utf8.count
        guard byteSize < maxBytes else { return }
        if entries[key] != nil { return }
        entries[key] = Entry(
            result: result,
            expiresAt: ttl.map { Date().addingTimeInterval($0) },
            lastAccess: Date(),
            byteSize: byteSize)
        totalBytes += byteSize
        stores += 1
        enforceLimits()
    }

    func evictAll() {
        entries.removeAll()
        totalBytes = 0
        evictions += 1
    }

    var stats: ToolCacheStats {
        ToolCacheStats(hits: hits, misses: misses, stores: stores, evictions: evictions)
    }

    var entryCount: Int { entries.count }

    private func enforceLimits() {
        guard entries.count > maxEntries || totalBytes > maxBytes else { return }
        let oldest = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, entry) in oldest {
            guard entries.count > maxEntries || totalBytes > maxBytes else { break }
            entries[key] = nil
            totalBytes -= entry.byteSize
            evictions += 1
        }
    }
}
