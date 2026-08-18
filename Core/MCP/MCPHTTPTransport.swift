import Foundation

/// Streamable-HTTP / SSE transport for MCP servers (spec 2025-03-26).
///
/// The client POSTs JSON-RPC messages to the server URL with
/// `Accept: application/json, text/event-stream`. The server answers either
/// with a single JSON body or with an SSE stream whose `data:` frames carry
/// the JSON-RPC responses/notifications. The `Mcp-Session-Id` header from
/// the initialize response is echoed on every later request.
///
/// Security posture matches the stdio connection: every tool exposed by a
/// server runs through the PermissionGate as `.execute` risk.

// MARK: - Pure SSE framing (unit-testable)

/// Incremental Server-Sent-Events parser. Feed raw bytes in any chunk
/// shape; completed `data:` events come back in order. Handles multi-line
/// `data:` (joined with `\n`), `event:` names, comments (`:`), and the
/// CRLF/LF line endings the spec allows.
final class SSEFrameParser: @unchecked Sendable {

    struct Event: Sendable, Equatable {
        var name: String?
        var data: String
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var currentData: [String] = []
    private var currentName: String?

    /// Feeds a chunk of bytes; returns every event completed by this chunk.
    func feed(_ chunk: Data) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            // Tolerate CRLF.
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                // Blank line terminates an event.
                if !currentData.isEmpty {
                    events.append(Event(name: currentName, data: currentData.joined(separator: "\n")))
                }
                currentData = []
                currentName = nil
                continue
            }
            guard let lineText = String(data: line, encoding: .utf8) else { continue }
            if lineText.hasPrefix(":") { continue }  // comment
            if let colon = lineText.firstIndex(of: ":") {
                let field = String(lineText[..<colon])
                var value = String(lineText[lineText.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                switch field {
                case "data": currentData.append(value)
                case "event": currentName = value
                default: break  // id/retry are irrelevant for JSON-RPC carriage
                }
            } else {
                // Field with no value.
                switch lineText {
                case "data": currentData.append("")
                default: break
                }
            }
        }
        return events
    }

    /// True when the buffered tail is an unterminated event (used by tests
    /// to assert chunk-boundary safety).
    var hasPendingEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !currentData.isEmpty || !buffer.isEmpty
    }
}

// MARK: - HTTP transport

/// One live HTTP/SSE connection to an MCP server.
actor MCPHTTPConnection: MCPTransport {

    enum HTTPError: Error, LocalizedError, Equatable {
        case badURL(String)
        case unauthorized(String)
        case transport(String)
        case timedOut(method: String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let detail): return "Invalid MCP server URL: \(detail)"
            case .unauthorized(let detail): return "MCP server rejected the request: \(detail)"
            case .transport(let detail): return "MCP transport failure: \(detail)"
            case .timedOut(let method): return "MCP request '\(method)' timed out"
            case .serverError(let message): return "MCP server error: \(message)"
            }
        }
    }

    struct ToolDefinition: Sendable, Equatable {
        var name: String
        var description: String
        var schemaJSON: String
    }

    private let name: String
    private let url: URL
    private let extraHeaders: [String: String]
    private let auth: MCPOAuthProvider?
    private var sessionID: String?
    private var nextID = 1
    private let session: URLSession
    private(set) var isAlive = false
    private var serverInfo = ""

    init(name: String, url: URL, headers: [String: String], auth: MCPOAuthProvider?) {
        self.name = name
        self.url = url
        self.extraHeaders = headers
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: Lifecycle

    /// Initialize handshake + tool listing. Throws on any failure — MCP is
    /// best-effort, the agent keeps its built-in tools.
    func connect() async throws -> [ToolDefinition] {
        isAlive = true

        let initParams = LFJSONValue.object([
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("BeetCode"),
                "version": .string("0.6.0"),
            ]),
        ])
        let initResult = try await request("initialize", params: initParams, timeout: 30)
        let serverName = initResult.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue ?? name
        let serverVersion = initResult.objectValue?["serverInfo"]?.objectValue?["version"]?.stringValue ?? ""
        serverInfo = serverVersion.isEmpty ? serverName : "\(serverName) \(serverVersion)"

        try? await notify("notifications/initialized")

        let listResult = try await request("tools/list", params: .object([:]), timeout: 30)
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
        isAlive = false
        session.invalidateAndCancel()
    }

    // MARK: Tool calls

    func callTool(_ toolName: String, argumentsJSON: String, timeout: TimeInterval = 60) async throws -> String {
        guard isAlive else { throw HTTPError.transport("connection closed") }
        let arguments = (try? LFJSONValue.decode(Data(argumentsJSON.utf8))) ?? .object([:])
        let params = LFJSONValue.object([
            "name": .string(toolName),
            "arguments": arguments,
        ])
        let result = try await request("tools/call", params: params, timeout: timeout)
        guard let object = result.objectValue else {
            throw HTTPError.serverError("malformed tools/call response")
        }
        if object["isError"]?.boolValue == true {
            throw HTTPError.serverError(Self.flattenContent(object["content"]) ?? "tool reported an error")
        }
        return Self.flattenContent(object["content"]) ?? "(no output)"
    }

    // MARK: Transport

    /// One JSON-RPC request over POST; answers arrive as either a plain JSON
    /// body or an SSE stream. With SSE, frames until the matching response id
    /// arrives; notifications are dropped.
    private func request(
        _ method: String, params: LFJSONValue, timeout: TimeInterval
    ) async throws -> LFJSONValue {
        let id = nextID
        nextID += 1
        let message = LFJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.timeoutInterval = timeout
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            httpRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in extraHeaders {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let auth {
            try await auth.apply(to: &httpRequest)
        }
        httpRequest.httpBody = Data(message.encoded().utf8)

        let (bytes, response) = try await session.bytes(for: httpRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.transport("non-HTTP response")
        }
        if method == "initialize", let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = sid
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            // One OAuth retry when the server supports it (spec §authorization).
            if let auth, !(await auth.didHandleUnauthorized) {
                await auth.markUnauthorizedHandled()
                try await auth.handleUnauthorized(for: url)
                return try await request(method, params: params, timeout: timeout)
            }
            throw HTTPError.unauthorized("HTTP \(http.statusCode)")
        default:
            throw HTTPError.transport("HTTP \(http.statusCode)")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            let parser = SSEFrameParser()
            // URLSession.AsyncBytes yields one UInt8 per iteration; batch into
            // the SSE parser in 4 KiB slices to keep framing incremental.
            var pending: [UInt8] = []
            pending.reserveCapacity(4096)
            for try await byte in bytes {
                if Task.isCancelled { throw HTTPError.transport("cancelled") }
                pending.append(byte)
                if pending.count >= 4096 {
                    if let match = try drain(parser: parser, chunk: Data(pending), awaitingID: id) {
                        return match
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                if let match = try drain(parser: parser, chunk: Data(pending), awaitingID: id) {
                    return match
                }
            }
            throw HTTPError.timedOut(method: method)
        }

        // Plain JSON body: collect fully.
        var body = Data()
        for try await byte in bytes {
            if Task.isCancelled { throw HTTPError.transport("cancelled") }
            body.append(byte)
        }
        guard let json = try? LFJSONValue.decode(body), let object = json.objectValue else {
            throw HTTPError.transport("malformed JSON response")
        }
        if let error = object["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? "unknown error"
            throw HTTPError.serverError(message)
        }
        return object["result"] ?? .object([:])
    }

    /// Feeds a chunk to the SSE parser; returns the JSON-RPC result whose id
    /// matches `awaitingID` (skipping notifications), or throws a server error.
    private func drain(
        parser: SSEFrameParser, chunk: Data, awaitingID: Int
    ) throws -> LFJSONValue? {
        for event in parser.feed(chunk) {
            guard let json = try? LFJSONValue.decode(Data(event.data.utf8)),
                  let object = json.objectValue else { continue }
            guard let idValue = object["id"], case .number(let idDouble) = idValue,
                  Int(idDouble) == awaitingID else { continue }
            if let error = object["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? "unknown error"
                throw HTTPError.serverError(message)
            }
            return object["result"] ?? .object([:])
        }
        return nil
    }

    /// Fire-and-forget notification.
    private func notify(_ method: String) async throws {
        let message = LFJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object([:]),
        ])
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID {
            httpRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in extraHeaders {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let auth {
            try await auth.apply(to: &httpRequest)
        }
        httpRequest.httpBody = Data(message.encoded().utf8)
        _ = try? await session.data(for: httpRequest)
    }

    // MARK: Helpers

    /// MCP tool results are content arrays; flatten text parts (binary parts
    /// are summarized, never injected raw) — same policy as the stdio path.
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
