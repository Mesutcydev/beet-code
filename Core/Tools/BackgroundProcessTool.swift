import Foundation

/// Long-lived workspace processes (dev servers) that survive across agent
/// turns. `run_command` always kills the process group when the tool returns;
/// this store keeps a Process alive, tees output into a log file, and lets
/// later turns list / read / stop it.
enum BackgroundProcessStore {

    struct Record: Sendable, Equatable {
        var id: String
        var command: String
        var pid: Int32
        var logPath: String
        var startedAt: Date
        var running: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [String: Process] = [:]
    nonisolated(unsafe) private static var records: [String: Record] = [:]
    nonisolated(unsafe) private static var nextID: Int = 1

    static func start(command: String, workingDirectory: URL) throws -> Record {
        let id: String = lock.withLock {
            let value = "bg-\(nextID)"
            nextID += 1
            return value
        }
        let logDir = workingDirectory.appendingPathComponent(".beetcode/processes", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("\(id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = ShellRunner.sanitizedEnvironment()
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        ChildProcessRegistry.register(process)

        let record = Record(
            id: id, command: command, pid: process.processIdentifier,
            logPath: logURL.path, startedAt: Date(), running: true)
        lock.withLock {
            processes[id] = process
            records[id] = record
        }
        process.terminationHandler = { proc in
            ChildProcessRegistry.unregister(proc)
            lock.withLock {
                if var existing = records[id] {
                    existing.running = false
                    records[id] = existing
                }
                processes[id] = nil
            }
            try? handle.close()
        }
        return record
    }

    static func list() -> [Record] {
        lock.withLock {
            records.values.map { record in
                var copy = record
                if let process = processes[record.id] {
                    copy.running = process.isRunning
                    copy.pid = process.processIdentifier
                } else {
                    copy.running = false
                }
                return copy
            }
            .sorted { $0.startedAt < $1.startedAt }
        }
    }

    static func logs(id: String, tail: Int) -> String? {
        let path = lock.withLock { records[id]?.logPath }
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(max(1, tail)).joined(separator: "\n")
    }

    @discardableResult
    static func stop(id: String) -> Bool {
        let process = lock.withLock { processes[id] }
        guard let process, process.isRunning else { return false }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        ChildProcessRegistry.unregister(process)
        lock.withLock {
            if var existing = records[id] {
                existing.running = false
                records[id] = existing
            }
            processes[id] = nil
        }
        return true
    }

    /// Test hook.
    static func resetAll() {
        let running = lock.withLock { Array(processes.values) }
        for process in running where process.isRunning {
            process.terminate()
            ChildProcessRegistry.unregister(process)
        }
        lock.withLock {
            processes.removeAll()
            records.removeAll()
        }
    }
}

struct BackgroundProcessTool: AgentTool {
    let name = "background_process"
    let summary = "Start or stop a long-running workspace process (dev server)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "action":{"type":"string","enum":["start","stop"]},
          "command":{"type":"string","description":"Shell command to start (action=start)"},
          "id":{"type":"string","description":"Process id from background_status (action=stop)"}
        },"required":["action"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let action = call.string("action") ?? "start"
        if action == "start", let command = call.string("command") {
            return .command("start background: \(command)")
        }
        if action == "stop", let id = call.string("id") {
            return .command("stop background \(id)")
        }
        return .command("background_process \(action)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let action = call.string("action") ?? ""
        switch action {
        case "start":
            guard let command = call.string("command"), !command.isEmpty else {
                throw ToolError.missingArgument("command")
            }
            let record = try BackgroundProcessStore.start(
                command: command, workingDirectory: context.workspace.root)
            return "started \(record.id) pid=\(record.pid)\nlog: \(record.logPath)\ncommand: \(record.command)"
        case "stop":
            guard let id = call.string("id") else { throw ToolError.missingArgument("id") }
            return BackgroundProcessStore.stop(id: id)
                ? "stopped \(id)"
                : "error: process \(id) is not running"
        default:
            return "error: action must be start or stop — use background_status to list or read logs"
        }
    }
}

struct BackgroundStatusTool: AgentTool {
    let name = "background_status"
    let summary = "List long-running workspace processes or read their logs"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "action":{"type":"string","enum":["list","logs"],"description":"Default list"},
          "id":{"type":"string","description":"Process id (required for logs)"},
          "tail":{"type":"integer","description":"Log lines to return (default 80, max 400)"}
        },"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let action = call.string("action") ?? "list"
        switch action {
        case "logs":
            guard let id = call.string("id") else { throw ToolError.missingArgument("id") }
            let tail = min(max(call.int("tail") ?? 80, 1), 400)
            guard let text = BackgroundProcessStore.logs(id: id, tail: tail) else {
                return "error: unknown process \(id)"
            }
            return text.isEmpty ? "(empty log)" : text
        default:
            let items = BackgroundProcessStore.list()
            guard !items.isEmpty else { return "(no background processes)" }
            return items.map { item in
                let state = item.running ? "running" : "exited"
                return "\(item.id)  pid=\(item.pid)  \(state)  \(item.command)"
            }.joined(separator: "\n")
        }
    }
}
