import Foundation
@testable import BeetCode

/// A uniquely-named temporary directory that removes itself on deinit.
/// Every test workspace goes through here so no test can touch real user
/// folders and nothing leaks onto disk after a run.
final class TempWorkspace {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Absolute URL for a workspace-relative path (no existence check).
    func url(for relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    @discardableResult
    func write(_ content: String, to relative: String) -> URL {
        let target = url(for: relative)
        try! FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! content.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    @discardableResult
    func makeDirectory(_ relative: String) -> URL {
        let target = url(for: relative)
        try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: relative).path)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: url(for: relative), encoding: .utf8)
    }

    var workspace: Workspace {
        Workspace(root: url)
    }
}

/// Runs real git against a TempWorkspace so checkpoint tests exercise the
/// actual repository behavior the checkpointer depends on.
final class GitRepo {
    let url: URL

    init(in workspace: TempWorkspace) {
        self.url = workspace.url
        let (status, _) = run(["init", "-q"])
        precondition(status == 0, "git init failed")
    }

    @discardableResult
    func run(_ arguments: String...) -> (status: Int32, output: String) {
        run(arguments)
    }

    @discardableResult
    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    func commitAll(message: String) -> String {
        let (status, _) = run(["add", "-A"])
        precondition(status == 0, "git add failed")
        let (commitStatus, output) = run([
            "-c", "user.name=BeetCode Tests",
            "-c", "user.email=test@beetcode.local",
            "commit", "-q", "-m", message,
        ])
        precondition(commitStatus == 0, "git commit failed: \(output)")
        return output
    }
}

/// Collects AgentLoop events from a stream for assertions. Polls with a
/// deadline so a hanging loop fails the test instead of deadlocking it.
/// Thread-safe (lock-protected), hence Sendable.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    private var finished: AgentFinish?

    var all: [AgentEvent] {
        withLock { events }
    }

    var finish: AgentFinish? {
        withLock { finished }
    }

    func start(_ stream: AsyncStream<AgentEvent>) async {
        for await event in stream {
            let isFinished = withLock { () -> Bool in
                events.append(event)
                if case .finished(let reason) = event { finished = reason }
                if case .finished = event { return true }
                return false
            }
            if isFinished { break }
        }
    }

    /// Waits (with a deadline) until the loop finishes. Returns the finish
    /// reason or nil on timeout — never blocks forever.
    func waitForFinish(timeout: TimeInterval = 10) async -> AgentFinish? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let finish { return finish }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Waits until a predicate over collected events holds, or times out.
    func waitUntil(
        timeout: TimeInterval = 10,
        _ predicate: ([AgentEvent]) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(all) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func events<T>(of kind: (AgentEvent) -> T?) -> [T] {
        all.compactMap(kind)
    }

    func assistantMessages() -> [String] {
        events { event in
            if case .assistantMessage(let text) = event { return text }
            return nil
        }
    }

    func toolCalls() -> [ToolInvocation] {
        events { event in
            if case .toolCallStarted(let invocation) = event { return invocation }
            return nil
        }
    }

    func approvals() -> [ApprovalRequest] {
        events { event in
            if case .awaitingApproval(let request) = event { return request }
            return nil
        }
    }

    func checkpoints() -> [SessionCheckpoint] {
        events { event in
            if case .checkpointCreated(let checkpoint) = event { return checkpoint }
            return nil
        }
    }

    func questions() -> [(UUID, String)] {
        events { event in
            if case .askUser(let id, let question) = event { return (id, question) }
            return nil
        }
    }

    func tokenDeltas() -> String {
        all.compactMap { event in
            if case .tokenDelta(let chunk) = event { return chunk }
            return nil
        }.joined()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}