import Foundation

/// Minimal HTTP/1.1 server over POSIX sockets — zero dependencies, matching
/// BeetCode's zero-dependency ethos (posix_spawn for shells, LFJSONValue
/// for JSON). Loopback-only by construction: binds 127.0.0.1 (or ::1 with
/// `bindIPv6`), so nothing outside this Mac can ever reach it.
///
/// Architecture: the actor owns lifecycle (config, sockets, running state).
/// All blocking syscalls (accept/read/write) run inside detached utility
/// tasks so the cooperative thread pool and the actor itself never stall.
/// Each connection gets its own task; requests on one connection are served
/// sequentially (read → route → write → next), which matches how local
/// coding tools talk to an inference server.
public actor LocalAPIServer {

    public struct Config: Sendable, Equatable {
        /// 0 lets the OS choose a free port (read back via `actualPort`).
        public var port: Int
        public var bindIPv6: Bool
        public var modelIDOverride: String?
        /// When set, every API request must carry a matching
        /// `Authorization: Bearer <token>` header (LM Studio-style). nil =
        /// open access, which is still loopback-only.
        public var bearerToken: String?
        /// Optional idle TTL: when no request arrives for this many seconds,
        /// the engine is unloaded (model leaves RAM/Metal). nil = keep
        /// resident. Mirrors LM Studio's "unload after idle".
        public var idleTTLSeconds: Int?

        public init(port: Int = 1234, bindIPv6: Bool = false, modelIDOverride: String? = nil, bearerToken: String? = nil, idleTTLSeconds: Int? = nil) {
            self.port = port
            self.bindIPv6 = bindIPv6
            self.modelIDOverride = modelIDOverride
            self.bearerToken = bearerToken
            self.idleTTLSeconds = idleTTLSeconds
        }
    }

    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let headers: [String: String]
        public let body: Data

        public var bodyJSON: LFJSONValue? {
            guard !body.isEmpty else { return nil }
            return try? LFJSONValue.decode(body)
        }

        /// HTTP/1.1 keep-alive by default; honor explicit "Connection: close".
        public var isKeepAlive: Bool {
            headers["connection"]?.lowercased() != "close"
        }
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public static func json(_ value: LFJSONValue, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: Data(value.encoded().utf8))
        }

        public static func text(_ text: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }
    }

    /// A route answers directly, or streams SSE lines (each element already a
    /// complete "data: ...\n\n" frame — see OpenAIRoutes).
    public enum RouteResult: Sendable {
        case response(Response)
        case stream(Response, lines: AsyncStream<Data>)
    }

    public typealias RouteHandler = @Sendable (Request) async -> RouteResult
    /// Resolves a request to a handler. Lets the app/CLI add or override
    /// routes without touching the transport.
    public typealias RouteResolver = @Sendable (Request) async -> RouteResult?

    public enum ServerError: Error, Equatable, LocalizedError {
        case bindFailed(Int32)
        case listenFailed(Int32)
        case alreadyRunning

        public var errorDescription: String? {
            switch self {
            case .bindFailed(let code): return "Could not bind port: errno \(code) (is the port already in use?)"
            case .listenFailed(let code): return "Could not listen on socket: errno \(code)"
            case .alreadyRunning: return "The local API server is already running."
            }
        }
    }

    private let engine: any LLMEngine
    private var config = Config()
    private var listeningFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var idleMonitorTask: Task<Void, Never>?
    private var connectionTasks: [Task<Void, Never>] = []
    private(set) public var isRunning = false
    /// The real bound port — differs from config.port when it was 0.
    private(set) public var actualPort: Int = 0
    /// Shared with off-actor connection handlers so requests can stamp the
    /// last-activity time without hopping to the actor per byte.
    private let activity = ActivityBox()

    private final class ActivityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        var lastActivity: Date {
            get { lock.lock(); defer { lock.unlock() }; return last }
            set { lock.lock(); last = newValue; lock.unlock() }
        }
    }

    public init(engine: any LLMEngine) {
        self.engine = engine
    }

    /// The model identifier reported by /v1/models and completion responses:
    /// loaded model first, then the configured override, then a fixed name.
    public func reportedModelID() async -> String {
        if let loaded = await engine.loadedModelID { return loaded }
        if let override = config.modelIDOverride, !override.isEmpty { return override }
        return "beetcode"
    }

    // MARK: Lifecycle

    public func start(_ newConfig: Config) async throws {
        guard !isRunning else { throw ServerError.alreadyRunning }
        config = newConfig

        let fd = socket(config.bindIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult: Int32
        if config.bindIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(config.port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(config.port).bigEndian)
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)  // 127.0.0.1
            bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bindFailed(code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.listenFailed(code)
        }

        // Read back the port the OS actually assigned (config.port may be 0).
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = named == 0 ? Int(UInt16(bigEndian: bound.sin_port)) : config.port
        actualPort = port > 0 ? port : config.port

        listeningFD = fd
        isRunning = true

        let engine = self.engine
        let bearerToken = config.bearerToken
        let activityBox = activity
        let weakResolver: RouteResolver = { [weak self] request in
            guard let self else { return nil }
            return await self.defaultRoute(for: request)
        }
        // The accept loop must NOT run on the actor — accept() blocks. A
        // detached task blocks its own thread instead, and closing the
        // listener socket in stop() ends the loop.
        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                guard clientFD >= 0 else { return }  // listener closed or fatal errno
                await self?.handleAccepted(clientFD, engine: engine, resolver: weakResolver, bearerToken: bearerToken, activity: activityBox)
            }
        }

        // Idle TTL: poll activity; unload the model after the quiet window.
        if let ttl = config.idleTTLSeconds, ttl > 0 {
            activity.lastActivity = Date()
            idleMonitorTask = Task { [weak self, engine, activityBox] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard self != nil else { return }
                    let idle = Date().timeIntervalSince(activityBox.lastActivity)
                    if idle >= Double(ttl), await engine.loadedModelID != nil {
                        await engine.unload()
                        activityBox.lastActivity = Date()  // avoid re-unload storms
                        Log.app.info("[api] Idle TTL (\(ttl)s) reached — model unloaded")
                    }
                }
            }
        }
        Log.app.info("[api] Local API server listening on http://127.0.0.1:\(self.actualPort, privacy: .public)")
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        if listeningFD >= 0 {
            close(listeningFD)  // unblocks accept() in the detached loop
            listeningFD = -1
        }
        acceptTask?.cancel()
        acceptTask = nil
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
        for task in connectionTasks { task.cancel() }
        connectionTasks.removeAll()
        Log.app.info("[api] Local API server stopped")
    }

    private func handleAccepted(_ fd: Int32, engine: any LLMEngine, resolver: @escaping RouteResolver, bearerToken: String?, activity: ActivityBox) {
        let task = Task.detached(priority: .utility) {
            await Self.serveConnection(fd, engine: engine, resolver: resolver, bearerToken: bearerToken, activity: activity)
        }
        connectionTasks.append(task)
        // Bound the bookkeeping list: drop finished tasks occasionally.
        if connectionTasks.count > 64 {
            connectionTasks.removeAll { $0.isCancelled }
        }
    }

    // MARK: Default routing (OpenAI-compatible surface)

    nonisolated private func defaultRoute(for request: Request) async -> RouteResult? {
        // Populated by OpenAIRoutes; kept on the resolver path so the CLI
        // could substitute a different engine surface later.
        nil
    }

    // MARK: Connection handling (off-actor)

    private static func serveConnection(
        _ fd: Int32, engine: any LLMEngine, resolver: @escaping RouteResolver,
        bearerToken: String?, activity: ActivityBox
    ) async {
        defer { close(fd) }
        while !Task.isCancelled {
            guard let request = await readRequest(fd) else { return }
            activity.lastActivity = Date()
            // CORS: browser-based clients (e.g. lattice-composer) need these
            // on every response, errors included.
            let extra = corsHeaders(for: request)

            // Bearer auth (when configured). Health checks are exempt so
            // monitoring stays trivial; everything else must authenticate.
            if let bearerToken, request.path != "/health" && request.path != "/healthz" {
                let header = request.headers["authorization"] ?? ""
                let expected = "Bearer \(bearerToken)"
                guard header == expected else {
                    let status = header.isEmpty ? 401 : 403
                    await writeResponse(fd, .json(
                        OpenAIRoutes.errorJSON(message: "Invalid or missing bearer token.", type: "authentication_error"),
                        status: status), extraHeaders: extra)
                    return
                }
            }

            let result = await OpenAIRoutes.route(request, engine: engine, resolver: resolver)
            switch result {
            case .response(let response):
                await writeResponse(fd, response, extraHeaders: extra)
            case .stream(let response, let lines):
                // SSE responses carry "Connection: close" — end the
                // connection after the stream instead of expecting more
                // requests on the same socket.
                await writeStreamedResponse(fd, response, extraHeaders: extra, lines: lines)
                return
            }
            if !request.isKeepAlive { return }
        }
    }

    private static func corsHeaders(for request: Request) -> [(String, String)] {
        let origin = request.headers["origin"] ?? "*"
        return [
            ("Access-Control-Allow-Origin", origin),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
        ]
    }

    // MARK: Request parsing

    static let maxBodyBytes = 32 * 1024 * 1024  // 32 MiB request cap

    private static func readRequest(_ fd: Int32) async -> Request? {
        var buffer = Data()
        var headerEnd: Int?
        while headerEnd == nil {
            guard let chunk = await readChunk(fd, limit: 65_536) else { return nil }
            if chunk.isEmpty { return nil }  // clean EOF before a complete request
            buffer.append(chunk)
            if buffer.count > 1_048_576 { return nil }  // header section cap: 1 MiB
            headerEnd = indexOfHeaderEnd(buffer)
        }
        guard let split = headerEnd else { return nil }
        let headerData = buffer.prefix(split)
        var body = Data(buffer.dropFirst(split))
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // curl sends "Expect: 100-continue" for large bodies; acknowledge
        // it so the body actually arrives.
        if headers["expect"]?.lowercased() == "100-continue" {
            _ = await writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength <= maxBodyBytes else { return nil }
        while body.count < contentLength {
            guard let chunk = await readChunk(fd, limit: min(65_536, contentLength - body.count)) else { return nil }
            if chunk.isEmpty { return nil }
            body.append(chunk)
        }
        if body.count > contentLength {
            body = Data(body.prefix(contentLength))
        }
        let (path, query) = splitTarget(target)
        return Request(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        var query: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            query[String(key)] = kv.count > 1 ? String(kv[1]) : ""
        }
        return (path, query)
    }

    private static func indexOfHeaderEnd(_ data: Data) -> Int? {
        // "\r\n\r\n" search over raw bytes.
        let needle: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == needle[0], bytes[i + 1] == needle[1],
               bytes[i + 2] == needle[2], bytes[i + 3] == needle[3] {
                return i + 4
            }
            i += 1
        }
        return nil
    }

    /// Blocking read isolated on a utility thread. Returns nil on error,
    /// empty Data on clean EOF.
    private static func readChunk(_ fd: Int32, limit: Int) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: limit, alignment: 8)
            defer { buffer.deallocate() }
            var n = -1
            repeat {
                n = read(fd, buffer, limit)
            } while n < 0 && errno == EINTR
            guard n > 0 else { return n == 0 ? Data() : nil }
            return Data(bytes: buffer, count: n)
        }.value
    }

    // MARK: Response writing

    private static func writeResponse(
        _ fd: Int32, _ response: Response, extraHeaders: [(String, String)]
    ) async {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: keep-alive\r\n\r\n"
        guard await writeAll(fd, Data(head.utf8)) else { return }
        if !response.body.isEmpty {
            _ = await writeAll(fd, response.body)
        }
    }

    private static func writeStreamedResponse(
        _ fd: Int32, _ response: Response, extraHeaders: [(String, String)],
        lines: AsyncStream<Data>
    ) async {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Cache-Control: no-cache\r\n"
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        guard await writeAll(fd, Data(head.utf8)) else { return }
        for await line in lines {
            let written = await writeChunked(fd, line)
            if !written { return }
        }
        _ = await writeChunked(fd, Data())  // terminating zero-length chunk
    }

    private static func writeChunked(_ fd: Int32, _ payload: Data) async -> Bool {
        var out = Data()
        out.append(Data(String(payload.count, radix: 16).utf8))
        out.append(Data([0x0d, 0x0a]))
        out.append(payload)
        out.append(Data([0x0d, 0x0a]))
        return await writeAll(fd, out)
    }

    /// Blocking writes isolated on a utility thread.
    private static func writeAll(_ fd: Int32, _ data: Data) async -> Bool {
        guard !data.isEmpty else { return true }
        return await Task.detached(priority: .utility) {
            var offset = 0
            let bytes = [UInt8](data)
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { raw -> Int in
                    var n = -1
                    repeat {
                        n = write(fd, raw.baseAddress! + offset, bytes.count - offset)
                    } while n < 0 && errno == EINTR
                    return n
                }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }.value
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}
