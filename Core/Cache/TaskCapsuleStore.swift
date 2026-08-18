import Foundation

/// Durable continuation state of an agent task. This is NOT disposable cache:
/// it lives in Application Support and must survive cache deletion, app
/// termination, and model unload. Deterministically extracted from the
/// session record (changed files, diagnostics, checks) plus the current
/// objective and epoch identity.
struct AgentTaskCapsule: Codable, Sendable, Equatable {
    let taskID: UUID
    let workspaceID: String
    let epochID: UUID

    var objective: String
    var changedFiles: [String]
    var unresolvedDiagnostics: [String]
    var completedChecks: [String]
    var lastUserInstruction: String

    var createdAt: Date
    var updatedAt: Date
}

/// Persists capsules under Application Support/AgentTasks — deliberately
/// outside the Caches tree so 'Clear Cache' can never destroy agent progress.
final class TaskCapsuleStore: @unchecked Sendable {

    static let shared = TaskCapsuleStore()

    /// Test seam: redirect storage to a temporary directory.
    var overrideDirectory: URL?

    private let lock = NSLock()

    private var directory: URL {
        if let overrideDirectory { return overrideDirectory }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("BeetCode/AgentTasks", isDirectory: true)
    }

    func save(_ capsule: AgentTaskCapsule) {
        let url = directory.appendingPathComponent("\(capsule.taskID.uuidString).json")
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(capsule) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func load(taskID: UUID) -> AgentTaskCapsule? {
        let url = directory.appendingPathComponent("\(taskID.uuidString).json")
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentTaskCapsule.self, from: data)
    }

    func delete(taskID: UUID) {
        let url = directory.appendingPathComponent("\(taskID.uuidString).json")
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
