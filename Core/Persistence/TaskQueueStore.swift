import Foundation

/// Durable lifecycle states for work that may outlive a browser request or an
/// app process. A running task is recovered as queued after relaunch because
/// a model stream cannot safely be resumed from the middle of a process.
enum QueuedTaskState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case awaitingApproval
    case awaitingQuestion
    case awaitingPlan
    case paused
    case completed
    case failed
    case stopped

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Waiting for you"
        case .awaitingPlan: "Plan ready"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Needs review"
        case .stopped: "Stopped"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped: true
        case .queued, .running, .awaitingApproval, .awaitingQuestion, .awaitingPlan, .paused: false
        }
    }

    var isInterrupted: Bool {
        switch self {
        case .running, .awaitingApproval, .awaitingQuestion, .awaitingPlan: true
        case .queued, .paused, .completed, .failed, .stopped: false
        }
    }
}

/// One prompt waiting for the single active model run. The model identifier
/// is a hint captured at enqueue time; credentials never enter this record.
struct QueuedAgentTask: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let workspacePath: String
    let message: String
    let modelID: String
    let source: String
    let createdAt: Date
    var updatedAt: Date
    var state: QueuedTaskState
    var phase: String?
    var attempts: Int
    var lastError: String?
    var resultSummary: String?
}

enum TaskQueueError: LocalizedError, Equatable {
    case invalidMessage
    case invalidWorkspace
    case queueFull

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "A queued task needs a non-empty message."
        case .invalidWorkspace: "A queued task needs an existing workspace folder."
        case .queueFull: "The task queue is full. Finish or remove an older task first."
        }
    }
}

/// File-backed queue under Application Support. Each task is encrypted with
/// the same Keychain-held local session key and written as a separate record,
/// so one corrupt task cannot hide the rest of the queue.
final class TaskQueueStore: @unchecked Sendable {

    static let shared = TaskQueueStore()
    static let maximumPendingTasks = 100

    /// Test seam: redirect the queue away from the real Application Support.
    var overrideDirectory: URL?

    private let lock = NSLock()

    private var directory: URL {
        if let overrideDirectory {
            try? FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
            return overrideDirectory
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("BeetCode/TaskQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    func enqueue(
        sessionID: UUID,
        workspacePath: String,
        message: String,
        modelID: String,
        source: String = "remote"
    ) throws -> QueuedAgentTask {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw TaskQueueError.invalidMessage }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw TaskQueueError.invalidWorkspace }

        let existing = loadAll()
        let pending = existing.filter { !$0.state.isTerminal }
        guard pending.count < Self.maximumPendingTasks else { throw TaskQueueError.queueFull }

        let now = Date()
        let task = QueuedAgentTask(
            id: UUID(),
            sessionID: sessionID,
            workspacePath: workspacePath,
            message: trimmedMessage,
            modelID: modelID,
            source: source,
            createdAt: now,
            updatedAt: now,
            state: .queued,
            phase: nil,
            attempts: 0,
            lastError: nil,
            resultSummary: nil)
        save(task)
        return task
    }

    func load(id: UUID) -> QueuedAgentTask? {
        let url = url(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    func loadAll() -> [QueuedAgentTask] {
        let dir = directory
        lock.lock()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        lock.unlock()
        return names
            .filter { $0.hasSuffix(".task") }
            .compactMap { name in
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return decode(data)
            }
            .sorted {
                if $0.state != $1.state {
                    return Self.stateRank($0.state) < Self.stateRank($1.state)
                }
                return $0.createdAt < $1.createdAt
            }
    }

    func update(_ id: UUID, _ mutate: (inout QueuedAgentTask) -> Void) {
        guard var task = load(id: id) else { return }
        mutate(&task)
        task.updatedAt = Date()
        save(task)
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Returns interrupted tasks to the queue after a process restart. The
    /// prompt will be replayed from its persisted session seed, never from a
    /// half-consumed in-memory model stream.
    @discardableResult
    func recoverInterrupted() -> [QueuedAgentTask] {
        var recovered: [QueuedAgentTask] = []
        for task in loadAll() where task.state.isInterrupted {
            update(task.id) { task in
                task.state = .queued
                task.phase = nil
                task.attempts += 1
                task.lastError = "Requeued after Beet Code restarted."
            }
            if let updated = load(id: task.id) { recovered.append(updated) }
        }
        return recovered
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).task")
    }

    private func save(_ task: QueuedAgentTask) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(task) else { return }
        guard let payload = SessionCrypto.encrypt(data) else { return }
        let target = url(for: task.id)
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? payload.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private func decode(_ data: Data) -> QueuedAgentTask? {
        let payload = SessionCrypto.decrypt(data) ?? data
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(QueuedAgentTask.self, from: payload)
    }

    private static func stateRank(_ state: QueuedTaskState) -> Int {
        switch state {
        case .running, .awaitingApproval, .awaitingQuestion, .awaitingPlan: 0
        case .queued, .paused: 1
        case .failed: 2
        case .stopped: 3
        case .completed: 4
        }
    }
}
