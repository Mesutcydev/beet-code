import AppKit
import Foundation

/// The account-backed OpenAI surface is intentionally implemented through
/// Codex's local app-server. Beet Code never handles the ChatGPT refresh
/// token, calls private ChatGPT web endpoints, or pretends a subscription is
/// an API key. Codex owns that authentication lifecycle.

// MARK: - Public account/model values

struct CodexAccountSummary: Sendable, Equatable {
    let email: String?
    let planType: String?

    var displayPlan: String {
        guard let planType, !planType.isEmpty else { return "ChatGPT account" }
        return planType.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct CodexModelProfile: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [String]
    let inputModalities: [String]
    let isDefault: Bool

    var supportsVision: Bool { inputModalities.contains("image") }
}

struct CodexBrowserLogin: Sendable, Equatable {
    let loginID: String
    let authURL: URL
}

struct CodexDeviceCodeLogin: Sendable, Equatable {
    let loginID: String
    let verificationURL: URL
    let userCode: String
}

struct CodexServerMessage: Sendable, Equatable {
    let method: String?
    let id: Int?
    let params: LFJSONValue?
    let result: LFJSONValue?
    let errorMessage: String?

    var isServerRequest: Bool { method != nil && id != nil && result == nil }
    var isNotification: Bool { method != nil && id == nil }
    var isResponse: Bool { method == nil && id != nil }

    init?(value: LFJSONValue) {
        guard let object = value.objectValue else { return nil }
        method = object["method"]?.stringValue
        id = object["id"]?.intValue
        params = object["params"]
        result = object["result"]
        errorMessage = object["error"]?.objectValue?["message"]?.stringValue
    }
}

enum CodexAppServerError: Error, LocalizedError, Equatable {
    case executableNotFound
    case spawnFailed(String)
    case processExited(Int32)
    case closed
    case timedOut(String)
    case serverError(String)
    case malformedResponse(String)
    case notAuthenticated
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install Codex or choose its executable in Settings."
        case .spawnFailed(let detail):
            return "Could not start Codex app-server: \(detail)"
        case .processExited(let status):
            return "Codex app-server exited unexpectedly (status \(status))."
        case .closed:
            return "Codex app-server is not running."
        case .timedOut(let method):
            return "Codex app-server timed out while handling " + method + "."
        case .serverError(let message):
            return message
        case .malformedResponse(let method):
            return "Codex app-server returned an invalid response for " + method + "."
        case .notAuthenticated:
            return "Sign in with ChatGPT before choosing an account-backed model."
        case .invalidURL:
            return "Codex returned an invalid browser login URL."
        }
    }
}

// MARK: - Local app-server process and JSON-RPC transport

actor CodexAppServerClient {

    private let requestedExecutableURL: URL?
    private let clientVersion: String

    private var process: Process?
    private var stdin: FileHandle?
    private var isAlive = false
    private var isInitialized = false
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<LFJSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<CodexServerMessage>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?
    private var inputBuffer = Data()

    init(executableURL: URL? = nil, clientVersion: String = "0.9.0") {
        self.requestedExecutableURL = executableURL
        self.clientVersion = clientVersion
    }

    /// Searches the same locations a GUI-launched macOS app can reasonably
    /// use. GUI apps often receive a shorter PATH than Terminal sessions, so
    /// the common user-local paths are explicit fallbacks.
    nonisolated static func discoverExecutable(customPath: String? = nil) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let customPath {
            candidates.append(customPath)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ])

        var seen = Set<String>()
        for candidate in candidates {
            guard seen.insert(candidate).inserted else { continue }
            let url = URL(fileURLWithPath: candidate)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: url.path)
            else { continue }
            return url
        }
        return nil
    }

    var executableURL: URL? {
        Self.discoverExecutable(customPath: requestedExecutableURL?.path)
    }

    var running: Bool { isAlive }

    func events() -> AsyncStream<CodexServerMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Lifecycle

    func start() async throws {
        if isAlive, isInitialized { return }
        await stop()
        guard let executableURL else { throw CodexAppServerError.executableNotFound }

        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.environment = ProcessInfo.processInfo.environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        // App-server keeps the JSONL protocol on stdout. Diagnostics belong
        // in the app's own log and must never corrupt the protocol stream.
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }

        process = child
        stdin = inputPipe.fileHandleForWriting
        isAlive = true
        isInitialized = false
        ChildProcessRegistry.register(child)

        child.terminationHandler = { [weak self] terminated in
            Task { await self?.markDead(status: terminated.terminationStatus) }
        }

        let reader = outputPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            var buffer = Data()
            while let self, await self.isAlive {
                let chunk = reader.availableData
                if chunk.isEmpty {
                    await self.markDead(status: child.terminationStatus)
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty { await self.dispatch(line: line) }
                }
            }
        }

        let initializeParams = LFJSONValue.object([
            "clientInfo": .object([
                "name": .string("beetcode"),
                "title": .string("Beet Code"),
                "version": .string(clientVersion)
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "mcpServerOpenaiFormElicitation": .bool(true)
            ])
        ])
        _ = try await request("initialize", params: initializeParams, timeout: 20)
        try sendNotification("initialized")
        isInitialized = true
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        stdin?.closeFile()
        stdin = nil
        if let process, process.isRunning { process.terminate() }
        if let process { ChildProcessRegistry.unregister(process) }
        process = nil
        isAlive = false
        isInitialized = false
        inputBuffer.removeAll(keepingCapacity: false)
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CodexAppServerError.closed) }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func markDead(status: Int32) {
        guard isAlive else { return }
        readerTask?.cancel()
        readerTask = nil
        stdin?.closeFile()
        stdin = nil
        if let process { ChildProcessRegistry.unregister(process) }
        process = nil
        isAlive = false
        isInitialized = false
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CodexAppServerError.processExited(status))
        }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: JSON-RPC requests

    func request(
        _ method: String,
        params: LFJSONValue = .object([:]),
        timeout: TimeInterval = 30
    ) async throws -> LFJSONValue {
        guard isAlive, isInitialized || method == "initialize" else {
            throw CodexAppServerError.closed
        }
        let id = nextRequestID
        nextRequestID += 1
        let message = LFJSONValue.object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(message)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeout(requestID: id, method: method)
            }
        }
    }

    private func timeout(requestID: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: CodexAppServerError.timedOut(method))
    }

    func sendNotification(_ method: String, params: LFJSONValue = .object([:])) throws {
        try write(.object([
            "method": .string(method),
            "params": params
        ]))
    }

    /// Replies to a server-initiated request (approvals, elicitation, and
    /// future app-server client requests). The documented v2 shape is a
    /// plain `{ "id": ..., "result": ... }` object.
    func respond(to requestID: Int, result: LFJSONValue) throws {
        try write(.object([
            "id": .number(Double(requestID)),
            "result": result
        ]))
    }

    private func write(_ message: LFJSONValue) throws {
        guard let stdin else { throw CodexAppServerError.closed }
        var data = Data(message.encoded().utf8)
        data.append(0x0A)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }
    }

    // MARK: Incoming JSONL

    private func dispatch(line: Data) {
        guard let value = try? LFJSONValue.decode(line),
              let message = CodexServerMessage(value: value)
        else {
            Log.app.warning("Codex app-server emitted malformed JSONL")
            return
        }

        if message.isResponse, let id = message.id,
           let continuation = pending.removeValue(forKey: id) {
            if let error = message.errorMessage {
                continuation.resume(throwing: CodexAppServerError.serverError(error))
            } else {
                continuation.resume(returning: message.result ?? .object([:]))
            }
            return
        }

        for continuation in subscribers.values { continuation.yield(message) }
    }

    // MARK: Supported app-server calls

    func readAccount(refreshToken: Bool = false) async throws -> CodexAccountSummary? {
        let response = try await request(
            "account/read",
            params: .object(["refreshToken": .bool(refreshToken)]))
        guard let account = response.objectValue?["account"]?.objectValue else { return nil }
        guard account["type"]?.stringValue == "chatgpt" else { return nil }
        return CodexAccountSummary(
            email: account["email"]?.stringValue,
            planType: account["planType"]?.stringValue)
    }

    func listModels() async throws -> [CodexModelProfile] {
        let response = try await request(
            "model/list",
            params: .object([
                "limit": .number(100),
                "includeHidden": .bool(false)
            ]))
        return (response.objectValue?["data"]?.arrayValue ?? []).compactMap(Self.modelProfile)
    }

    func startBrowserLogin() async throws -> CodexBrowserLogin {
        let response = try await request(
            "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("chatgpt")
            ]))
        guard let object = response.objectValue,
              let loginID = object["loginId"]?.stringValue,
              let rawURL = object["authUrl"]?.stringValue,
              let authURL = URL(string: rawURL)
        else { throw CodexAppServerError.invalidURL }
        return CodexBrowserLogin(loginID: loginID, authURL: authURL)
    }

    func startDeviceCodeLogin() async throws -> CodexDeviceCodeLogin {
        let response = try await request(
            "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")]))
        guard let object = response.objectValue,
              let loginID = object["loginId"]?.stringValue,
              let rawURL = object["verificationUrl"]?.stringValue,
              let verificationURL = URL(string: rawURL),
              let userCode = object["userCode"]?.stringValue
        else { throw CodexAppServerError.malformedResponse("account/login/start") }
        return CodexDeviceCodeLogin(
            loginID: loginID,
            verificationURL: verificationURL,
            userCode: userCode)
    }

    func cancelLogin(loginID: String) async throws {
        _ = try await request(
            "account/login/cancel",
            params: .object(["loginId": .string(loginID)]))
    }

    func logout() async throws {
        _ = try await request("account/logout")
    }

    func startThread(
        modelID: String,
        workspace: URL,
        chatOnly: Bool = false
    ) async throws -> String {
        let response = try await request(
            "thread/start",
            params: .object([
                "model": .string(modelID),
                "cwd": .string(workspace.path),
                "approvalPolicy": .string(chatOnly ? "never" : "on-request"),
                "sandbox": .string(chatOnly ? "read-only" : "workspace-write"),
                "serviceName": .string("beetcode")
            ]))
        guard let thread = response.objectValue?["thread"]?.objectValue,
              let id = thread["id"]?.stringValue
        else { throw CodexAppServerError.malformedResponse("thread/start") }
        return id
    }

    func resumeThread(
        threadID: String,
        modelID: String,
        workspace: URL,
        chatOnly: Bool = false
    ) async throws -> String {
        let response = try await request(
            "thread/resume",
            params: .object([
                "threadId": .string(threadID),
                "model": .string(modelID),
                "cwd": .string(workspace.path),
                "approvalPolicy": .string(chatOnly ? "never" : "on-request"),
                "sandbox": .string(chatOnly ? "read-only" : "workspace-write"),
                "serviceName": .string("beetcode")
            ]))
        guard let thread = response.objectValue?[
            "thread"]?.objectValue,
              let id = thread["id"]?.stringValue
        else { throw CodexAppServerError.malformedResponse("thread/resume") }
        return id
    }

    func startTurn(
        threadID: String,
        modelID: String,
        workspace: URL,
        text: String,
        chatOnly: Bool = false
    ) async throws -> String {
        let response = try await request(
            "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]),
                "cwd": .string(workspace.path),
                "model": .string(modelID),
                "approvalPolicy": .string(chatOnly ? "never" : "on-request"),
                "sandboxPolicy": .object([
                    "type": .string(chatOnly ? "readOnly" : "workspaceWrite"),
                    "writableRoots": chatOnly ? .array([]) : .array([.string(workspace.path)]),
                    "networkAccess": .bool(!chatOnly)
                ]),
                "summary": .string("concise")
            ]))
        guard let turn = response.objectValue?["turn"]?.objectValue,
              let id = turn["id"]?.stringValue
        else { throw CodexAppServerError.malformedResponse("turn/start") }
        return id
    }

    func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request(
            "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ]),
            timeout: 10)
    }

    func respondToApproval(requestID: Int, decision: String) async throws {
        try respond(
            to: requestID,
            result: .object(["decision": .string(decision)]))
    }

    func respondToPermissions(requestID: Int, permissions: LFJSONValue, scope: String) async throws {
        try respond(
            to: requestID,
            result: .object([
                "permissions": permissions,
                "scope": .string(scope)
            ]))
    }

    func respondToUserInput(
        requestID: Int,
        questionID: String,
        answer: String?
    ) async throws {
        let answers: LFJSONValue = answer.map {
            .object([
                questionID: .object([
                    "answers": .array([.string($0)])
                ])
            ])
        } ?? .object([:])
        try respond(
            to: requestID,
            result: .object(["answers": answers]))
    }

    func declineDynamicTool(requestID: Int) async throws {
        try respond(
            to: requestID,
            result: .object([
                "contentItems": .array([]),
                "success": .bool(false)
            ]))
    }

    func declineElicitation(requestID: Int) async throws {
        try respond(
            to: requestID,
            result: .object([
                "action": .string("decline"),
                "content": .null
            ]))
    }

    // MARK: Parsing helpers

    private static func modelProfile(_ value: LFJSONValue) -> CodexModelProfile? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue ?? object["model"]?.stringValue
        else { return nil }
        let effortValues = object["supportedReasoningEfforts"]?.arrayValue ?? []
        return CodexModelProfile(
            id: id,
            displayName: object["displayName"]?.stringValue ?? id,
            description: object["description"]?.stringValue ?? "",
            defaultReasoningEffort: object["defaultReasoningEffort"]?.stringValue,
            supportedReasoningEfforts: effortValues.compactMap {
                $0.objectValue?["reasoningEffort"]?.stringValue ?? $0.stringValue
            },
            inputModalities: object["inputModalities"]?.arrayValue?.compactMap(\.stringValue)
                ?? ["text", "image"],
            isDefault: object["isDefault"]?.boolValue ?? false)
    }
}

// MARK: - Main-actor account state

@MainActor
final class CodexAccountStore: ObservableObject {

    static let shared = CodexAccountStore()

    let client: CodexAppServerClient

    @Published private(set) var isAvailable = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var account: CodexAccountSummary?
    @Published private(set) var models: [CodexModelProfile] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var browserLogin: CodexBrowserLogin?
    @Published private(set) var deviceCodeLogin: CodexDeviceCodeLogin?

    private var observationTask: Task<Void, Never>?

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    deinit { observationTask?.cancel() }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            try await client.start()
            isAvailable = true
            beginObservationIfNeeded()
            account = try await client.readAccount()
            isSignedIn = account != nil
            if isSignedIn {
                do {
                    models = try await client.listModels()
                } catch {
                    // A temporary model-catalog failure must not make a
                    // valid ChatGPT session look signed out. Keep account
                    // state and let the user retry the catalog independently.
                    models = []
                    errorMessage = "Signed in, but the OpenAI model list could not be loaded: \(error.localizedDescription)"
                }
            } else {
                models = []
            }
        } catch {
            isAvailable = await client.executableURL != nil
            isSignedIn = false
            account = nil
            models = []
            errorMessage = error.localizedDescription
        }
    }

    func signInWithBrowser() async {
        do {
            errorMessage = nil
            try await client.start()
            isAvailable = true
            beginObservationIfNeeded()
            let login = try await client.startBrowserLogin()
            browserLogin = login
            NSWorkspace.shared.open(login.authURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithDeviceCode() async {
        do {
            errorMessage = nil
            try await client.start()
            isAvailable = true
            beginObservationIfNeeded()
            let login = try await client.startDeviceCodeLogin()
            deviceCodeLogin = login
            NSWorkspace.shared.open(login.verificationURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelLogin() async {
        let loginID = browserLogin?.loginID ?? deviceCodeLogin?.loginID
        browserLogin = nil
        deviceCodeLogin = nil
        guard let loginID else { return }
        try? await client.cancelLogin(loginID: loginID)
    }

    func signOut() async {
        do {
            try await client.logout()
            account = nil
            models = []
            isSignedIn = false
            browserLogin = nil
            deviceCodeLogin = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshModels() async {
        do {
            try await client.start()
            beginObservationIfNeeded()
            models = try await client.listModels()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginObservationIfNeeded() {
        guard observationTask == nil else { return }
        let client = self.client
        observationTask = Task { [weak self] in
            let stream = await client.events()
            for await message in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.handle(message) }
            }
            await MainActor.run { self?.observationTask = nil }
        }
    }

    private func handle(_ message: CodexServerMessage) {
        guard let method = message.method, let params = message.params?.objectValue else { return }
        switch method {
        case "account/login/completed":
            browserLogin = nil
            deviceCodeLogin = nil
            let success = params["success"]?.boolValue ?? false
            if success {
                Task { await self.refresh() }
            } else {
                errorMessage = params["error"]?.stringValue ?? "ChatGPT sign-in was not completed."
            }
        case "account/updated":
            if params["authMode"]?.stringValue == "chatgpt" {
                Task { await self.refresh() }
            } else if params["authMode"]?.stringValue == nil {
                account = nil
                models = []
                isSignedIn = false
            }
        default:
            break
        }
    }
}
