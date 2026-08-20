import Foundation

/// One MCP server configuration entry. Two transport shapes, mirroring the
/// Claude Code / OpenCode convention so existing configs mostly work:
///
/// ```json
/// { "mcpServers": {
///     "fs":      { "command": "mcp-fs", "args": ["--root", "."], "env": {} },
///     "remote":  { "url": "https://mcp.example.com/v1" },
///     "gated":   { "url": "https://mcp.example.com/v1",
///                  "oauth": { "clientId": "…", "clientSecret": "…" },
///                  "headers": { "X-Team": "ops" } }
/// } }
/// ```
///
/// A `command` entry is stdio; a `url` entry is Streamable-HTTP (with SSE
/// response carriage). Entries with both prefer `command`.
struct MCPServerConfig: Codable, Equatable, Sendable {
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var headers: [String: String] = [:]
    var oauth: OAuthConfig?

    private enum CodingKeys: String, CodingKey {
        case command, args, env, url, headers, oauth
    }

    init(command: String? = nil, args: [String] = [], env: [String: String] = [:],
         url: String? = nil, headers: [String: String] = [:], oauth: OAuthConfig? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.oauth = oauth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        oauth = try c.decodeIfPresent(OAuthConfig.self, forKey: .oauth)
    }

    struct OAuthConfig: Codable, Equatable, Sendable {
        var clientId: String?
        var clientSecret: String?
    }

    enum Transport: Equatable {
        case stdio
        case http
    }

    var transport: Transport {
        command?.isEmpty == false ? .stdio : (url != nil ? .http : .stdio)
    }
}

struct MCPConfigFile: Codable, Equatable, Sendable {
    var mcpServers: [String: MCPServerConfig] = [:]
}

/// Loads MCP server definitions from two locations; workspace-local entries
/// override user-global ones with the same name:
///   1. `~/.beetcode/mcp.json`            (user-global)
///   2. `<workspace>/.beetcode/mcp.json`  (project-local)
enum MCPConfig {

    static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".beetcode/mcp.json")
    }

    static func workspaceConfigURL(root: URL) -> URL {
        root.appendingPathComponent(".beetcode/mcp.json")
    }

    /// Merged servers: user-global plus workspace-local (local wins on name
    /// collision). Invalid files are ignored with a reason string so the UI
    /// can surface them without breaking the agent.
    static func load(
        workspaceRoot: URL,
        includeOpenCode: Bool = true
    ) -> (servers: [String: MCPServerConfig], errors: [String]) {
        var merged: [String: MCPServerConfig] = [:]
        var errors: [String] = []

        // OpenCode uses the same transport vocabulary with an `mcp` root
        // object. Import it before Beet Code's native files so an explicit
        // `.beetcode/mcp.json` entry remains the local override.
        if includeOpenCode {
            let openCode = OpenCodeCompatibility.load(workspace: workspaceRoot)
            merged.merge(openCode.mcpServers) { _, local in local }
            errors.append(contentsOf: openCode.warnings)
        }

        for (label, url) in [("user", userConfigURL), ("workspace", workspaceConfigURL(root: workspaceRoot))] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(MCPConfigFile.self, from: data)
                for (name, config) in decoded.mcpServers {
                    // A server needs EITHER a stdio command or an HTTP url.
                    let hasCommand = config.command?.isEmpty == false
                    let hasURL = config.url != nil && URL(string: config.url ?? "") != nil
                    guard hasCommand || hasURL else {
                        errors.append("\(label) config: server '\(name)' has neither a command nor a valid url")
                        continue
                    }
                    merged[name] = config
                }
            } catch {
                errors.append("\(label) config (\(url.lastPathComponent)): \(error.localizedDescription)")
            }
        }
        return (merged, errors)
    }
}

/// One live stdio connection to an MCP server: newline-delimited JSON-RPC
/// 2.0 over the child's stdin/stdout. Requests are matched to responses by
/// id; server notifications are acknowledged and dropped.
///
/// Security posture: every tool exposed by a server runs through the normal
/// PermissionGate as `.execute` risk — an MCP server can never bypass the
/// approval flow.
actor MCPConnection: MCPTransport {

    enum MCPError: Error, LocalizedError, Equatable {
        case spawnFailed(String)
        case notInitialized
        case timedOut(method: String)
        case serverError(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let detail): "MCP server failed to start: \(detail)"
            case .notInitialized: "MCP connection is not initialized"
            case .timedOut(let method): "MCP request '\(method)' timed out"
            case .serverError(let message): "MCP server error: \(message)"
            case .closed: "MCP connection closed"
            }
        }
    }

    struct ToolDefinition: Sendable, Equatable {
        var name: String
        var description: String
        /// The server's input schema, passed through to the system prompt.
        var schemaJSON: String
    }

    /// Continuations waiting on a response id. Lock-guarded (not actor state)
    /// so they can be registered inside `withCheckedThrowingContinuation`'s
    /// @Sendable closure and resumed from the timer task without isolation
    /// gymnastics. Exactly-once resumption is guaranteed by `take`.
    private final class PendingStore: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [Int: CheckedContinuation<LFJSONValue, Error>] = [:]

        func store(_ continuation: CheckedContinuation<LFJSONValue, Error>, id: Int) {
            lock.lock(); defer { lock.unlock() }
            continuations[id] = continuation
        }

        func take(id: Int) -> CheckedContinuation<LFJSONValue, Error>? {
            lock.lock(); defer { lock.unlock() }
            return continuations.removeValue(forKey: id)
        }

        func failAll(_ error: MCPError) {
            lock.lock()
            let all = continuations
            continuations.removeAll()
            lock.unlock()
            for (_, continuation) in all {
                continuation.resume(throwing: error)
            }
        }
    }

    private let name: String
    private let config: MCPServerConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var nextID = 1
    private let pending = PendingStore()
    private(set) var isAlive = false
    private var serverInfo = ""

    init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
    }

    // MARK: Lifecycle

    /// Spawns the server, performs the initialize handshake, and returns the
    /// advertised tools. Throws on any failure — callers treat MCP as
    /// best-effort (the agent still runs with built-in tools).
    func connect() async throws -> [ToolDefinition] {
        let child = Process()
        // The registry only routes stdio transport when a command is set.
        guard let command = config.command, !command.isEmpty else {
            throw MCPError.spawnFailed("no command configured")
        }
        child.executableURL = Self.resolveExecutable(command)
        child.arguments = config.args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env { environment[key] = value }
        // Keep the child's stdio protocol clean.
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment

        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw MCPError.spawnFailed(error.localizedDescription)
        }
        process = child
        stdinPipe = input
        isAlive = true

        child.terminationHandler = { [weak self] _ in
            Task { await self?.markDead() }
        }

        // Reader loop: one JSON-RPC message per line.
        let reader = output.fileHandleForReading
        Task { [weak self] in
            var buffer = Data()
            while let self, await self.isAlive {
                let chunk = reader.availableData
                if chunk.isEmpty {
                    // EOF: the server exited.
                    await self.markDead()
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    await self.dispatch(line: Data(line))
                }
            }
        }

        // Initialize handshake (bounded).
        let initParams = LFJSONValue.object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("BeetCode"),
                "version": .string("0.5.0"),
            ]),
        ])
        let initResult = try await request("initialize", params: initParams, timeout: 15)
        let serverName = initResult.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue ?? name
        let serverVersion = initResult.objectValue?["serverInfo"]?.objectValue?["version"]?.stringValue ?? ""
        serverInfo = serverVersion.isEmpty ? serverName : "\(serverName) \(serverVersion)"

        // The spec requires the initialized notification before tool calls.
        try? sendNotification("notifications/initialized")

        let listResult = try await request("tools/list", params: .object([:]), timeout: 15)
        var tools: [ToolDefinition] = []
        for entry in listResult.objectValue?["tools"]?.arrayValue ?? [] {
            guard let object = entry.objectValue,
                  let toolName = object["name"]?.stringValue, !toolName.isEmpty
            else { continue }
            tools.append(ToolDefinition(
                name: toolName,
                description: object["description"]?.stringValue ?? "",
                schemaJSON: object["inputSchema"]?.encoded() ?? "{}"))
        }
        return tools
    }

    func disconnect() async {
        guard isAlive else { return }
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        isAlive = false
        pending.failAll(MCPError.closed)
    }

    // MARK: Requests

    /// Calls a server tool; returns the flattened text content.
    func callTool(_ toolName: String, argumentsJSON: String, timeout: TimeInterval = 60) async throws -> String {
        guard isAlive else { throw MCPError.closed }
        let arguments = (try? LFJSONValue.decode(Data(argumentsJSON.utf8))) ?? .object([:])
        let params = LFJSONValue.object([
            "name": .string(toolName),
            "arguments": arguments,
        ])
        let result = try await request("tools/call", params: params, timeout: timeout)
        guard let object = result.objectValue else {
            throw MCPError.serverError("malformed tools/call response")
        }
        if object["isError"]?.boolValue == true {
            throw MCPError.serverError(Self.flattenContent(object["content"]) ?? "tool reported an error")
        }
        return Self.flattenContent(object["content"]) ?? "(no output)"
    }

    private func request(
        _ method: String, params: LFJSONValue, timeout: TimeInterval
    ) async throws -> LFJSONValue {
        guard isAlive else { throw MCPError.closed }
        let id = nextID
        nextID += 1
        let message = LFJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        try writeMessage(message)

        // Exactly-once: either the reader resumes us with the response, or
        // the timer resumes us with .timedOut — whichever takes the id first.
        let pendingStore = pending
        let serverName = method
        return try await withCheckedThrowingContinuation { continuation in
            pendingStore.store(continuation, id: id)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let timedOut = pendingStore.take(id: id) {
                    timedOut.resume(throwing: MCPError.timedOut(method: serverName))
                }
            }
        }
    }

    private func sendNotification(_ method: String, params: LFJSONValue = .object([:])) throws {
        let message = LFJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        try writeMessage(message)
    }

    private func writeMessage(_ message: LFJSONValue) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else { throw MCPError.closed }
        var data = Data(message.encoded().utf8)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    // MARK: Incoming

    private func dispatch(line: Data) {
        guard let json = try? LFJSONValue.decode(line), let object = json.objectValue else { return }
        // Responses carry an id; notifications/requests from the server don't
        // (we advertise no capabilities, so only notifications are expected).
        guard let idValue = object["id"], case .number(let idDouble) = idValue else { return }
        let id = Int(idDouble)
        guard let continuation = pending.take(id: id) else { return }
        if let error = object["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? "unknown error"
            continuation.resume(throwing: MCPError.serverError(message))
        } else {
            continuation.resume(returning: object["result"] ?? .object([:]))
        }
    }

    private func markDead() {
        isAlive = false
        pending.failAll(MCPError.closed)
    }

    // MARK: Helpers

    /// Resolves a bare command name against PATH (the config convention), or
    /// uses an absolute path as-is.
    nonisolated static func resolveExecutable(_ command: String) -> URL {
        if command.hasPrefix("/") { return URL(fileURLWithPath: command) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    /// MCP tool results are content arrays; flatten text parts (images and
    /// other binary parts are summarized, never injected raw).
    nonisolated static func flattenContent(_ value: LFJSONValue?) -> String? {
        guard let array = value?.arrayValue else {
            return value?.stringValue
        }
        let parts: [String] = array.compactMap { entry in
            guard let object = entry.objectValue else { return entry.stringValue }
            switch object["type"]?.stringValue {
            case "text": return object["text"]?.stringValue
            case .some(let kind): return "[\(kind) content omitted]"
            case nil: return object["text"]?.stringValue
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    var displayName: String {
        serverInfo.isEmpty ? name : "\(name) (\(serverInfo))"
    }
}
