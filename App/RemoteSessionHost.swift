import Foundation
import AppKit
import Darwin
import Security
import CryptoKit

enum RemoteNetworkKind: String, Equatable, Sendable {
    case tailscale
    case localNetwork
}

/// Owns the network-facing Beetcode browser surface.
///
/// This is deliberately a session controller, not a terminal bridge: the
/// browser sees encrypted Beetcode session records and sends the next prompt
/// through `AgentSessionController`, so the Mac continues the exact same
/// workspace, transcript, checkpoints, and model context.
@MainActor
final class RemoteSessionHost {

    nonisolated static let defaultPort = 9475
    static let pairingLifetime: TimeInterval = 10 * 60
    /// Browser access survives normal phone/laptop use, while the QR itself
    /// remains a short-lived, one-time approval. Revocation still takes
    /// effect immediately and stopping the host clears every token.
    static let tokenLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maxMessageBytes = 20_000
    static let maxPairBodyBytes = 4 * 1024
    static let maxRemoteBodyBytes = 64 * 1024
    static let maxPairedClients = 8
    static let maxPairFailuresPerWindow = 8
    static let pairFailureWindow: TimeInterval = 60

    enum HostError: Error, LocalizedError, Equatable {
        case tailscaleUnavailable
        case noReachableAddress

        var errorDescription: String? {
            switch self {
            case .tailscaleUnavailable:
                return "Tailscale is not connected. Connect Tailscale, or enable the trusted local-network fallback in Settings."
            case .noReachableAddress:
                return "No reachable network address was found for remote sessions."
            }
        }
    }

    private let engine: any LLMEngine
    private let sessions: AgentSessionController
    /// AppState installs these handlers so remote messages become durable
    /// queued tasks. Tests and lightweight hosts may leave them nil and keep
    /// the direct continuation behavior.
    var enqueueTaskHandler: ((UUID, String) -> QueuedAgentTask?)?
    var taskLookupHandler: ((UUID) -> QueuedAgentTask?)?
    private var server: LocalAPIServer?
    private var tokens: [String: Date] = [:]
    /// Invalidates an in-flight bind when Settings changes or the host is
    /// stopped. LocalAPIServer.start awaits socket setup, so this guard keeps
    /// an older start from publishing itself after a newer request wins.
    private var startGeneration = 0
    private struct PairFailureWindow {
        var count: Int
        var firstAt: Date
    }
    private var pairFailuresByAddress: [String: PairFailureWindow] = [:]
    private(set) var boundPort: Int?
    private(set) var pairingCode = RemoteSessionHost.makePairingCode()
    private(set) var pairingExpiresAt = Date().addingTimeInterval(RemoteSessionHost.pairingLifetime)
    private(set) var networkHost: String?
    private(set) var networkKind: RemoteNetworkKind?

    init(engine: any LLMEngine, sessions: AgentSessionController) {
        self.engine = engine
        self.sessions = sessions
    }

    var isRunning: Bool { server != nil }
    var actualPort: Int? { boundPort }

    var pairingURL: String? {
        guard let port = actualPort, let host = networkHost else { return nil }
        return "http://\(host):\(port)/?pair=\(pairingCode)"
    }

    var browserURL: String? {
        guard let port = actualPort, let host = networkHost else { return nil }
        return "http://\(host):\(port)/"
    }

    var pairedClientCount: Int {
        pruneExpiredTokens()
        return tokens.count
    }

    func start(port: Int, allowLAN: Bool = false) async throws {
        startGeneration &+= 1
        let generation = startGeneration
        let endpoint = RemoteNetworkEndpointDiscovery.preferredEndpoint(allowLAN: allowLAN)
        if let server {
            if await server.isRunning {
                let currentPort = await server.actualPort
                if let endpoint,
                   (port == 0 || currentPort == port),
                   networkHost == endpoint.host,
                   networkKind == endpoint.kind { return }
                await server.stop()
            }
            self.server = nil
            boundPort = nil
        }

        guard let endpoint else {
            networkHost = nil
            networkKind = nil
            if allowLAN {
                throw HostError.noReachableAddress
            }
            throw HostError.tailscaleUnavailable
        }

        networkHost = endpoint.host
        networkKind = endpoint.kind
        rotatePairingCode()
        let nextServer = LocalAPIServer(engine: engine)
        let resolver: LocalAPIServer.RouteResolver = { [weak self] request in
            guard let self else { return nil }
            return await self.route(request)
        }
        do {
            try await nextServer.start(
                .init(
                    port: port,
                    bindIPv6: false,
                    bindHost: "0.0.0.0",
                    modelIDOverride: nil,
                    bearerToken: nil,
                    idleTTLSeconds: nil,
                    exposeStandardRoutes: false,
                    maxBodyBytes: Self.maxRemoteBodyBytes,
                    allowCORS: false),
                routeResolver: resolver)
            guard !Task.isCancelled, generation == startGeneration else {
                await nextServer.stop()
                throw CancellationError()
            }
        } catch {
            if generation == startGeneration {
                networkHost = nil
                networkKind = nil
                boundPort = nil
            }
            throw error
        }
        let actualPort = await nextServer.actualPort
        guard !Task.isCancelled, generation == startGeneration else {
            await nextServer.stop()
            throw CancellationError()
        }
        server = nextServer
        boundPort = actualPort
        refreshPairingState()
    }

    func stop() async {
        startGeneration &+= 1
        await server?.stop()
        server = nil
        boundPort = nil
        tokens.removeAll()
        networkHost = nil
        networkKind = nil
        pairFailuresByAddress.removeAll()
    }

    func rotatePairingCode() {
        pairingCode = Self.makePairingCode()
        pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
        pairFailuresByAddress.removeAll()
    }

    /// Rotates an expired code even when nobody opens the pairing sheet. This
    /// keeps the displayed code and the code accepted by the listener aligned.
    func refreshPairingState() {
        if Date() >= pairingExpiresAt {
            rotatePairingCode()
        }
    }

    func revokeAllClients() {
        tokens.removeAll()
        rotatePairingCode()
    }

    // MARK: HTTP routes

    private func route(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        refreshPairingState()
        guard allowedPeer(request.remoteAddress) else {
            return .response(json(["error": .string("This network path is not allowed for Beetcode remote sessions.")], status: 403))
        }
        guard allowedOrigin(request) else {
            return .response(json(["error": .string("This browser origin is not the Beetcode remote host.")], status: 403))
        }

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return .response(securityResponse(status: 204, contentType: "text/plain"))
        case ("GET", "/"), ("GET", "/index.html"):
            return .response(htmlPage())
        case ("GET", "/assets/beetlogo.png"):
            return .response(logoResponse())
        case ("POST", "/api/pair"):
            return pair(request)
        case ("GET", "/api/status"):
            guard authorized(request) else { return unauthorized() }
            return .response(json([
                "product": .string("Beet Code Remote"),
                "protocolVersion": .number(1),
                "pairedClients": .number(Double(pairedClientCount)),
                "networkKind": .string(networkKind?.rawValue ?? "unknown"),
                "tokenExpiresAt": tokenDigest(from: request).flatMap { tokens[$0] }.map { .number($0.timeIntervalSince1970) } ?? .null,
                "activeSessionID": sessions.activeSessionID.map { .string($0.uuidString) } ?? .null,
                "isRunning": .bool(sessions.isRunning),
                "phase": .string(sessions.currentPhase.rawValue),
                "queuedTasks": .number(Double(taskQueueCount)),
            ]))
        case ("GET", "/api/sessions"):
            guard authorized(request) else { return unauthorized() }
            return .response(json(["sessions": .array(sessionSummaries())]))
        case ("POST", "/api/revoke"):
            guard authorized(request) else { return unauthorized() }
            guard let digest = tokenDigest(from: request) else { return unauthorized() }
            tokens.removeValue(forKey: digest)
            return .response(json(["ok": .bool(true), "revoked": .bool(true)]))
        default:
            guard authorized(request) else { return unauthorized() }
            return sessionRoute(request)
        }
    }

    private func pair(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        guard request.body.count <= Self.maxPairBodyBytes else {
            return .response(json(["error": .string("Pairing requests must be under 4 KB.")], status: 413))
        }
        let address = request.remoteAddress
        guard canAttemptPairing(from: address) else {
            return .response(json(["error": .string("Too many pairing attempts. Try again in a minute.")], status: 429))
        }

        let submittedCodes = [
            request.bodyJSON?.objectValue?["code"]?.stringValue,
            request.query["pair"],
        ].compactMap { $0.flatMap(Self.normalizePairingCode) }
        guard submittedCodes.contains(where: { Self.constantTimeEqual($0, pairingCode) }),
              Date() < pairingExpiresAt else {
            recordPairFailure(from: address)
            return .response(json(["error": .string("The pairing code is invalid or expired.")], status: 401))
        }

        let token = Self.makeToken()
        let tokenExpiresAt = Date().addingTimeInterval(Self.tokenLifetime)
        if tokens.count >= Self.maxPairedClients,
           let oldest = tokens.min(by: { $0.value < $1.value })?.key {
            tokens.removeValue(forKey: oldest)
        }
        tokens[Self.tokenDigest(token)] = tokenExpiresAt
        // Pairing codes are approvals, not reusable passwords.
        rotatePairingCode()
        return .response(json([
            "token": .string(token),
            "expiresAt": .number(tokenExpiresAt.timeIntervalSince1970),
            "product": .string("Beet Code Remote"),
        ]))
    }

    private func sessionRoute(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        let components = request.path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "api",
              components[1] == "sessions",
              let id = UUID(uuidString: String(components[2])) else {
            return .response(json(["error": .string("Unknown endpoint.")], status: 404))
        }

        if components.count == 3, request.method == "GET" {
            guard let record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            return .response(json(sessionDetail(record)))
        }

        if components.count == 4, components[3] == "messages", request.method == "POST" {
            guard let message = request.bodyJSON?.objectValue?["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= Self.maxMessageBytes else {
                return .response(json(["error": .string("A non-empty message under 20 KB is required.")], status: 400))
            }
            guard let record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            if let enqueueTaskHandler {
                guard let task = enqueueTaskHandler(record.id, message) else {
                    return .response(json(["error": .string("The task could not be queued. Check the workspace and queue capacity.")], status: 409))
                }
                return .response(json([
                    "accepted": .bool(true),
                    "queued": .bool(true),
                    "taskID": .string(task.id.uuidString),
                    "state": .string(task.state.rawValue),
                    "sessionID": .string(record.id.uuidString),
                ], status: 202))
            }
            guard !sessions.isRunning else {
                return .response(json(["error": .string("Beet Code is already working on another prompt.")], status: 409))
            }
            guard sessions.continuePersistedSession(id: record.id, message: message) else {
                return .response(json(["error": .string("That session could not be resumed. Check that its workspace still exists.")], status: 409))
            }
            return .response(json([
                "accepted": .bool(true),
                "sessionID": .string(record.id.uuidString),
            ], status: 202))
        }

        if components.count == 4, components[3] == "approval", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  let pending = sessions.pendingApproval,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == pending.id,
                  let approved = request.bodyJSON?.objectValue?["approved"]?.boolValue else {
                return .response(json(["error": .string("That approval is no longer pending.")], status: 409))
            }
            let always = request.bodyJSON?.objectValue?["always"]?.boolValue ?? false
            sessions.approve(approved, always: always)
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "question", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  let pendingID = sessions.pendingQuestionRequestID,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == pendingID,
                  let answer = request.bodyJSON?.objectValue?["answer"]?.stringValue,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= Self.maxMessageBytes else {
                return .response(json(["error": .string("That question is no longer pending, or the answer is invalid.")], status: 409))
            }
            sessions.answerQuestion(answer)
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "plan", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  sessions.pendingPlan != nil,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == sessions.pendingPlanRequestID,
                  let action = request.bodyJSON?.objectValue?["action"]?.stringValue else {
                return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
            }
            switch action {
            case "approve":
                guard sessions.approvePlan(requestID: UUID(uuidString: requestID)) else {
                    return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
                }
            case "revise":
                guard let feedback = request.bodyJSON?.objectValue?["feedback"]?.stringValue,
                      !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      feedback.utf8.count <= Self.maxMessageBytes else {
                    return .response(json(["error": .string("Plan feedback must be non-empty and under 20 KB.")], status: 400))
                }
                guard sessions.revisePlan(feedback, requestID: UUID(uuidString: requestID)) else {
                    return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
                }
            default:
                return .response(json(["error": .string("Use approve or revise for a pending plan.")], status: 400))
            }
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "stop", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning else {
                return .response(json(["error": .string("That session is not running.")], status: 409))
            }
            sessions.stop()
            return .response(json(["accepted": .bool(true)]))
        }

        return .response(json(["error": .string("Unknown endpoint.")], status: 404))
    }

    private func sessionSummaries() -> [LFJSONValue] {
        let activeID = sessions.activeSessionID
        return SessionStore.shared.cachedAll(maxAge: 2)
            .filter { $0.source == .app }
            .prefix(100)
            .map { record in
                .object([
                    "id": .string(record.id.uuidString),
                    "title": .string(Self.displayTitle(record)),
                    "workspace": .string(Self.workspaceName(record.workspacePath)),
                    "messageCount": .number(Double(record.messages.count)),
                    "updatedAt": .number(record.updatedAt.timeIntervalSince1970),
                    "isCurrent": .bool(activeID == record.id),
                    "isRunning": .bool(activeID == record.id && sessions.isRunning),
                    "phase": .string(activeID == record.id ? sessions.currentPhase.rawValue : AgentPhase.idle.rawValue),
                    "queueState": taskLookupHandler?(record.id).map { .string($0.state.rawValue) } ?? .null,
                ])
            }
    }

    private func sessionDetail(_ record: SessionRecord) -> [String: LFJSONValue] {
        let activeID = sessions.activeSessionID
        let messages = record.messages.suffix(120).compactMap { message -> LFJSONValue? in
            guard message.role != .system else { return nil }
            let content = SessionStore.redact(message.content)
            return .object([
                "role": .string(message.role.rawValue),
                "content": .string(String(content.prefix(16_000))),
                "toolName": message.toolName.map { .string($0) } ?? .null,
                "timestamp": .number(message.timestamp.timeIntervalSince1970),
            ])
        }
        let isCurrent = activeID == record.id
        let isRunning = isCurrent && sessions.isRunning
        let liveText = isRunning
            ? String(SessionStore.redact(sessions.streamingText).prefix(16_000))
            : ""
        var detail: [String: LFJSONValue] = [
            "id": .string(record.id.uuidString),
            "title": .string(Self.displayTitle(record)),
            "workspace": .string(Self.workspaceName(record.workspacePath)),
            "modelID": .string(record.modelID),
            "updatedAt": .number(record.updatedAt.timeIntervalSince1970),
            "messages": .array(Array(messages)),
            "isCurrent": .bool(isCurrent),
            "isRunning": .bool(isRunning),
            "phase": .string(isCurrent ? sessions.currentPhase.rawValue : AgentPhase.idle.rawValue),
            "streamingText": .string(liveText),
        ]
        detail["pending"] = pendingInteraction(for: record.id)
        if let task = taskLookupHandler?(record.id) {
            detail["queue"] = .object([
                "id": .string(task.id.uuidString),
                "state": .string(task.state.rawValue),
                "label": .string(task.phase ?? task.state.label),
                "attempts": .number(Double(task.attempts)),
            ])
        }
        return detail
    }

    private var taskQueueCount: Int {
        Set(SessionStore.shared.cachedAll(maxAge: 2).compactMap { record in
            taskLookupHandler?(record.id)?.id
        }).count
    }

    private func ownedRecord(_ id: UUID) -> SessionRecord? {
        guard let record = SessionStore.shared.load(id: id),
              record.source == .app,
              SessionStore.shared.validateWorkspaceBinding(record) else { return nil }
        return record
    }

    private func authorized(_ request: LocalAPIServer.Request) -> Bool {
        pruneExpiredTokens()
        guard let digest = tokenDigest(from: request) else { return false }
        return tokens[digest] != nil
    }

    private func tokenDigest(from request: LocalAPIServer.Request) -> String? {
        guard let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : Self.tokenDigest(token)
    }

    private func pruneExpiredTokens() {
        let now = Date()
        tokens = tokens.filter { $0.value > now }
    }

    private func unauthorized() -> LocalAPIServer.RouteResult {
        .response(json(["error": .string("Pair this browser with the code shown in Beet Code.")], status: 401))
    }

    private func json(_ fields: [String: LFJSONValue], status: Int = 200) -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response.json(.object(fields), status: status)
        response.headers = Self.securityHeaders
        return response
    }

    private func htmlPage() -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response.html(RemoteSessionPage.html)
        response.headers = Self.securityHeaders + [
            ("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"),
            ("X-Frame-Options", "DENY"),
        ]
        return response
    }

    private func logoResponse() -> LocalAPIServer.Response {
        guard let image = NSImage(named: NSImage.Name("BeetLogo")),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return LocalAPIServer.Response(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Logo unavailable".utf8), headers: Self.securityHeaders)
        }
        return LocalAPIServer.Response(
            status: 200,
            contentType: "image/png",
            body: png,
            headers: Self.securityHeaders + [("Content-Disposition", "inline")])
    }

    private func securityResponse(status: Int, contentType: String) -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response(status: status, contentType: contentType)
        response.headers = Self.securityHeaders
        return response
    }

    private static let securityHeaders: [(String, String)] = [
        ("Cache-Control", "no-store, max-age=0"),
        ("Pragma", "no-cache"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]

    private func allowedOrigin(_ request: LocalAPIServer.Request) -> Bool {
        guard let rawOrigin = request.headers["origin"], !rawOrigin.isEmpty else { return true }
        guard rawOrigin != "null",
              !rawOrigin.contains(where: { $0 == "\r" || $0 == "\n" }),
              let origin = URLComponents(string: rawOrigin),
              let scheme = origin.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let originHost = origin.host?.lowercased(),
              let hostHeader = request.headers["host"],
              let hostComponents = URLComponents(string: "http://\(hostHeader)"),
              let requestHost = hostComponents.host?.lowercased(),
              originHost == requestHost,
              origin.user == nil,
              origin.password == nil,
              origin.path.isEmpty,
              origin.query == nil,
              origin.fragment == nil else { return false }
        let originPort = origin.port ?? (scheme == "https" ? 443 : 80)
        let expectedPort = hostComponents.port ?? 80
        guard originPort == expectedPort,
              expectedPort == boundPort else { return false }

        // The Host header alone is not an origin allowlist: a DNS-rebinding
        // page could make both Host and Origin attacker-controlled. Accept
        // the advertised numeric endpoint, plus explicit loopback access for
        // local debugging, and reject every other browser origin.
        let trustedHosts = Set([networkHost?.lowercased(), "127.0.0.1", "localhost"].compactMap { $0 })
        return trustedHosts.contains(originHost)
    }

    private func allowedPeer(_ address: String) -> Bool {
        guard address != "unknown" else { return false }
        if address == "127.0.0.1" || address == "::1" { return true }
        switch networkKind {
        case .tailscale:
            return RemoteNetworkEndpointDiscovery.isTailscale(address)
        case .localNetwork:
            return RemoteNetworkEndpointDiscovery.isPrivateIPv4(address)
        case nil:
            return false
        }
    }

    private func pendingInteraction(for id: UUID) -> LFJSONValue {
        guard sessions.activeSessionID == id else { return .null }
        if let approval = sessions.pendingApproval {
            let preview: LFJSONValue
            switch approval.preview {
            case .none:
                preview = .object(["kind": .string("none")])
            case .command(let command):
                preview = .object([
                    "kind": .string("command"),
                    "content": .string(String(command.prefix(12_000))),
                ])
            case .diff(let diff, let path):
                preview = .object([
                    "kind": .string("diff"),
                    "path": .string(path),
                    "content": .string(String(diff.unified.prefix(12_000))),
                    "added": .number(Double(diff.addedCount)),
                    "removed": .number(Double(diff.removedCount)),
                ])
            }
            return .object([
                "kind": .string("approval"),
                "requestID": .string(approval.id.uuidString),
                "toolName": .string(approval.invocation.name),
                "summary": .string(String(approval.invocation.summary.prefix(12_000))),
                "preview": preview,
            ])
        }
        if let question = sessions.pendingQuestion,
           let requestID = sessions.pendingQuestionRequestID {
            return .object([
                "kind": .string("question"),
                "requestID": .string(requestID.uuidString),
                "content": .string(String(question.prefix(12_000))),
            ])
        }
        if let plan = sessions.pendingPlan {
            return .object([
                "kind": .string("plan"),
                "requestID": sessions.pendingPlanRequestID.map { .string($0.uuidString) } ?? .null,
                "content": .string(String(plan.prefix(16_000))),
            ])
        }
        return .null
    }

    private func canAttemptPairing(from address: String) -> Bool {
        prunePairFailures()
        guard let window = pairFailuresByAddress[address] else { return true }
        return window.count < Self.maxPairFailuresPerWindow
    }

    private func recordPairFailure(from address: String) {
        prunePairFailures()
        let now = Date()
        var window = pairFailuresByAddress[address] ?? PairFailureWindow(count: 0, firstAt: now)
        window.count += 1
        pairFailuresByAddress[address] = window
        if window.count >= Self.maxPairFailuresPerWindow {
            rotatePairingCode()
        }
    }

    private func prunePairFailures() {
        let now = Date()
        pairFailuresByAddress = pairFailuresByAddress.filter {
            now.timeIntervalSince($0.value.firstAt) < Self.pairFailureWindow
        }
    }

    private static func displayTitle(_ record: SessionRecord) -> String {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "Session" ? "Untitled session" : title
    }

    private static func workspaceName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "Project" : URL(fileURLWithPath: path).lastPathComponent
    }

    private static func makePairingCode() -> String {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        let number = status == errSecSuccess ? Int(value % 1_000_000) : Int.random(in: 0...999_999)
        return String(format: "%06d", number)
    }

    private static func makeToken() -> String {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            data = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func tokenDigest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizePairingCode(_ raw: String) -> String? {
        var digits = ""
        digits.reserveCapacity(6)
        for character in raw {
            if character.isWhitespace || character == "-" || character == "·" { continue }
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            digits.append(String(value))
        }
        return digits.count == 6 ? digits : nil
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt8(left.count ^ right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Chooses a phone-reachable address. Tailscale's CGNAT range wins so the QR
/// works away from home; otherwise the first private LAN address is used only
/// when the user explicitly enables that fallback.
enum RemoteNetworkEndpointDiscovery {
    struct Endpoint: Equatable, Sendable {
        let host: String
        let kind: RemoteNetworkKind
    }

    static func preferredHost() -> String? {
        preferredEndpoint(allowLAN: true)?.host
    }

    static func preferredEndpoint(allowLAN: Bool) -> Endpoint? {
        var tailscale: String?
        var lan: String?
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return nil }
        defer { freeifaddrs(interfacePointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard value != "127.0.0.1" else { continue }
            if isTailscale(value) { tailscale = value }
            else if isPrivateIPv4(value), lan == nil { lan = value }
        }
        if let tailscale { return Endpoint(host: tailscale, kind: .tailscale) }
        guard allowLAN, let lan else { return nil }
        return Endpoint(host: lan, kind: .localNetwork)
    }

    static func isTailscale(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 || parts[0] == 192 && parts[1] == 168 { return true }
        return parts[0] == 172 && (16...31).contains(parts[1])
    }
}
