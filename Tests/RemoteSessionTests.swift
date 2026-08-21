import Foundation
import XCTest
@testable import BeetCode

@MainActor
final class RemoteSessionTests: XCTestCase {

    func testRemoteNetworkPrefersTailscaleAddressRange() {
        XCTAssertTrue(RemoteNetworkEndpointDiscovery.isTailscale("100.64.0.1"))
        XCTAssertTrue(RemoteNetworkEndpointDiscovery.isTailscale("100.127.255.254"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isTailscale("100.63.255.254"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isTailscale("192.168.1.20"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isTailscale("not-an-ip"))
    }

    func testRemoteNetworkAllowsOnlyExpectedPrivateRanges() {
        XCTAssertTrue(RemoteNetworkEndpointDiscovery.isPrivateIPv4("10.0.0.8"))
        XCTAssertTrue(RemoteNetworkEndpointDiscovery.isPrivateIPv4("172.16.10.4"))
        XCTAssertTrue(RemoteNetworkEndpointDiscovery.isPrivateIPv4("192.168.1.20"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isPrivateIPv4("172.15.10.4"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(RemoteNetworkEndpointDiscovery.isPrivateIPv4("192.168.1.999"))
    }

    func testRemotePageIsBeetCodeSessionSurface() {
        XCTAssertTrue(RemoteSessionPage.html.contains("Beet Code Remote"))
        XCTAssertTrue(RemoteSessionPage.html.contains("Continue this coding task"))
        XCTAssertTrue(RemoteSessionPage.html.contains("/api/sessions/"))
        XCTAssertTrue(RemoteSessionPage.html.contains("id=\"session-list\""))
        XCTAssertTrue(RemoteSessionPage.html.contains("/approval"))
        XCTAssertTrue(RemoteSessionPage.html.contains("/question"))
        XCTAssertTrue(RemoteSessionPage.html.contains("/plan"))
        XCTAssertTrue(RemoteSessionPage.html.contains("streamingText"))
        XCTAssertTrue(RemoteSessionPage.html.contains("phaseLabel"))
        XCTAssertTrue(RemoteSessionPage.html.contains("max-width: 720px"))
        XCTAssertTrue(RemoteSessionPage.html.contains("/assets/beetlogo.png"))
        XCTAssertTrue(RemoteSessionPage.html.contains("data-theme-choice=\"light\""))
        XCTAssertTrue(RemoteSessionPage.html.contains("data-theme-choice=\"dark\""))
        XCTAssertTrue(RemoteSessionPage.html.contains("data-theme-choice=\"beet\""))
        XCTAssertTrue(RemoteSessionPage.html.contains("querySelectorAll('[data-theme-choice]')"))
        XCTAssertFalse(RemoteSessionPage.html.contains("$('[data-theme-choice"))
        XCTAssertTrue(RemoteSessionPage.html.contains("height: 100svh"))
        XCTAssertTrue(RemoteSessionPage.html.contains("grid-template-columns: minmax(0, 1fr)"))
        XCTAssertTrue(RemoteSessionPage.html.contains("min-height: 48px"))
        XCTAssertTrue(RemoteSessionPage.html.contains("AbortController"))
        XCTAssertTrue(RemoteSessionPage.html.contains("visibilitychange"))
        XCTAssertTrue(RemoteSessionPage.html.contains("pageshow"))
        XCTAssertTrue(RemoteSessionPage.html.contains("MAX_RETRY_DELAY_MS"))
        XCTAssertTrue(RemoteSessionPage.html.contains("CURRENT_SESSION_KEY"))
        XCTAssertTrue(RemoteSessionPage.html.contains("sessions-toggle"))
        XCTAssertTrue(RemoteSessionPage.html.contains(".sidebar.compact"))
        XCTAssertTrue(RemoteSessionPage.html.contains("Show all sessions"))
        XCTAssertTrue(RemoteSessionPage.html.contains("height: auto"))
        XCTAssertTrue(RemoteSessionPage.html.contains("100dvh"))
        XCTAssertTrue(RemoteSessionPage.html.contains("loadSession(quiet, false)"))
        XCTAssertFalse(RemoteSessionPage.html.contains("innerHTML"))
        XCTAssertFalse(RemoteSessionPage.html.contains("terminalOutput"))
    }

    func testRemoteServerConfigDefaultsRemainLoopbackAndStandardRoutes() {
        let config = LocalAPIServer.Config()
        XCTAssertEqual(config.bindHost, "127.0.0.1")
        XCTAssertTrue(config.exposeStandardRoutes)
        XCTAssertFalse(config.allowCORS)

        let remoteConfig = LocalAPIServer.Config(
            port: RemoteSessionHost.defaultPort,
            bindHost: "0.0.0.0",
            exposeStandardRoutes: false,
            maxBodyBytes: RemoteSessionHost.maxRemoteBodyBytes,
            allowCORS: false)
        XCTAssertEqual(remoteConfig.bindHost, "0.0.0.0")
        XCTAssertFalse(remoteConfig.exposeStandardRoutes)
        XCTAssertEqual(remoteConfig.maxBodyBytes, RemoteSessionHost.maxRemoteBodyBytes)
        XCTAssertFalse(remoteConfig.allowCORS)
        XCTAssertEqual(RemoteSessionHost.tokenLifetime, 30 * 24 * 60 * 60)
    }

    func testControllerPublishesReasoningIntoTranscriptBeforeAnswer() async throws {
        let workspace = TempWorkspace()
        let sessionDirectory = TempWorkspace()
        let previousDirectory = SessionStore.shared.overrideSessionsDir
        let previousCurrentSession = SessionStore.shared.currentSessionID
        let settings = SettingsStore.shared
        let previousShowReasoning = settings.showReasoning
        let previousPlanMode = settings.planMode
        let previousAutoApproveEdits = settings.autoApproveEdits
        let previousAutoApproveCommands = settings.autoApproveCommands
        SessionStore.shared.overrideSessionsDir = sessionDirectory.url
        SessionStore.shared.currentSessionID = nil
        settings.showReasoning = true
        settings.planMode = false
        settings.autoApproveEdits = false
        settings.autoApproveCommands = false
        defer {
            SessionStore.shared.overrideSessionsDir = previousDirectory
            SessionStore.shared.currentSessionID = previousCurrentSession
            settings.showReasoning = previousShowReasoning
            settings.planMode = previousPlanMode
            settings.autoApproveEdits = previousAutoApproveEdits
            settings.autoApproveCommands = previousAutoApproveCommands
        }

        let engine = FakeLLMEngine()
        engine.enqueue(.text("<think>inspect the project</think>Here is the answer."))
        let controller = AgentSessionController(
            engine: engine,
            settings: settings,
            thermal: ThermalMonitor())
        await controller.switchWorkspace(to: workspace.url)

        controller.send("Inspect the project")
        for _ in 0..<200 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.transcript.contains { item in
            if case .reasoning("inspect the project") = item.kind { return true }
            return false
        })
        XCTAssertTrue(controller.transcript.contains { item in
            if case .assistant("Here is the answer.") = item.kind { return true }
            return false
        })
    }

    func testControllerStopCancelsActiveGeneration() async throws {
        let workspace = TempWorkspace()
        let sessionDirectory = TempWorkspace()
        let previousDirectory = SessionStore.shared.overrideSessionsDir
        let previousCurrentSession = SessionStore.shared.currentSessionID
        let settings = SettingsStore.shared
        let previousPlanMode = settings.planMode
        SessionStore.shared.overrideSessionsDir = sessionDirectory.url
        SessionStore.shared.currentSessionID = nil
        settings.planMode = false
        defer {
            SessionStore.shared.overrideSessionsDir = previousDirectory
            SessionStore.shared.currentSessionID = previousCurrentSession
            settings.planMode = previousPlanMode
        }

        let engine = FakeLLMEngine()
        engine.enqueue(.text("this response should be stopped"))
        engine.holdNextStream()
        let controller = AgentSessionController(
            engine: engine,
            settings: settings,
            thermal: ThermalMonitor())
        await controller.switchWorkspace(to: workspace.url)

        controller.send("Stop this task")
        let startDeadline = Date().addingTimeInterval(5)
        while engine.streamCallCount < 1 && Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.streamCallCount, 1)

        controller.stop()
        let stopDeadline = Date().addingTimeInterval(5)
        while controller.isRunning && Date() < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(engine.isCancelRequested)
        XCTAssertEqual(controller.finishReason, .cancelled)
    }

    func testRemotePairingIsOneTimeAndResumesTheSavedBeetCodeSession() async throws {
        try XCTSkipUnless(
            RemoteNetworkEndpointDiscovery.preferredEndpoint(allowLAN: false) != nil,
            "Tailscale is not connected in this environment")

        let workspace = TempWorkspace()
        let sessionDirectory = TempWorkspace()
        let previousDirectory = SessionStore.shared.overrideSessionsDir
        let previousCurrentSession = SessionStore.shared.currentSessionID
        let settings = SettingsStore.shared
        let previousPlanMode = settings.planMode
        let previousAutoApproveEdits = settings.autoApproveEdits
        let previousAutoApproveCommands = settings.autoApproveCommands
        SessionStore.shared.overrideSessionsDir = sessionDirectory.url
        SessionStore.shared.currentSessionID = nil
        settings.planMode = false
        settings.autoApproveEdits = true
        settings.autoApproveCommands = true
        defer {
            SessionStore.shared.overrideSessionsDir = previousDirectory
            SessionStore.shared.currentSessionID = previousCurrentSession
            settings.planMode = previousPlanMode
            settings.autoApproveEdits = previousAutoApproveEdits
            settings.autoApproveCommands = previousAutoApproveCommands
        }

        let engine = FakeLLMEngine()
        let controller = AgentSessionController(
            engine: engine,
            settings: SettingsStore.shared,
            thermal: ThermalMonitor())
        await controller.switchWorkspace(to: workspace.url)

        let sessionID = UUID()
        let now = Date()
        let record = SessionRecord(
            id: sessionID,
            title: "Continue the remote task",
            createdAt: now,
            updatedAt: now,
            workspacePath: workspace.url.path,
            modelID: "test-model",
            messages: [
                SessionMessage(role: .user, content: "Inspect the project", toolName: nil, timestamp: now),
                SessionMessage(role: .assistant, content: "I’m ready for the next instruction.", toolName: nil, timestamp: now),
            ],
            checkpoints: [])
        SessionStore.shared.save(record)
        SessionStore.shared.invalidateCache()

        let host = RemoteSessionHost(engine: engine, sessions: controller)
        addTeardownBlock {
            await host.stop()
        }
        try await host.start(port: 0, allowLAN: false)
        XCTAssertEqual(host.networkKind, .tailscale)

        let port = try XCTUnwrap(host.actualPort)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

        let page = try await request(baseURL, path: "/")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.body.contains("Beet Code Remote"))
        XCTAssertNotNil(page.headers["Content-Security-Policy"])

        let logo = try await request(baseURL, path: "/assets/beetlogo.png")
        XCTAssertEqual(logo.status, 200)
        XCTAssertEqual(logo.headers["content-type"], "image/png")

        let rejectedOrigin = try await request(
            baseURL,
            path: "/api/pair",
            method: "POST",
            body: Data("{\"code\":\"000000\"}".utf8),
            headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(rejectedOrigin.status, 403)

        let code = host.pairingCode
        let pair = try await request(
            baseURL,
            path: "/api/pair",
            method: "POST",
            body: Data("{\"code\":\"\(code)\"}".utf8))
        XCTAssertEqual(pair.status, 200)
        let token = try XCTUnwrap(pair.json.objectValue?["token"]?.stringValue)
        XCTAssertGreaterThan(token.utf8.count, 32)

        // A pairing code is an approval, not a reusable password.
        let replay = try await request(
            baseURL,
            path: "/api/pair",
            method: "POST",
            body: Data("{\"code\":\"\(code)\"}".utf8))
        XCTAssertEqual(replay.status, 401)

        let unauthorized = try await request(baseURL, path: "/api/status")
        XCTAssertEqual(unauthorized.status, 401)

        let status = try await request(baseURL, path: "/api/status", token: token)
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(status.json.objectValue?["networkKind"]?.stringValue, "tailscale")
        XCTAssertNotNil(status.json.objectValue?["tokenExpiresAt"]?.numberValue)
        XCTAssertNotNil(status.json.objectValue?["phase"]?.stringValue)

        // The remote listener is a session-control surface, never the local
        // OpenAI-compatible inference API.
        let models = try await request(baseURL, path: "/v1/models", token: token)
        XCTAssertEqual(models.status, 404)

        let sessions = try await request(baseURL, path: "/api/sessions", token: token)
        XCTAssertEqual(sessions.status, 200)
        XCTAssertTrue(sessions.body.contains(sessionID.uuidString))

        engine.enqueue(.text("Remote continuation complete."))
        let continuation = try await request(
            baseURL,
            path: "/api/sessions/\(sessionID.uuidString)/messages",
            method: "POST",
            token: token,
            body: Data("{\"message\":\"Continue from the phone\"}".utf8))
        XCTAssertEqual(continuation.status, 202)

        let inFlightDetail = try await request(baseURL, path: "/api/sessions/\(sessionID.uuidString)", token: token)
        XCTAssertEqual(inFlightDetail.status, 200)
        XCTAssertNotNil(inFlightDetail.json.objectValue?["phase"]?.stringValue)
        XCTAssertNotNil(inFlightDetail.json.objectValue?["streamingText"]?.stringValue)

        let finishDeadline = Date().addingTimeInterval(10)
        while controller.finishReason == nil, Date() < finishDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(controller.finishReason, .completed("Remote continuation complete."))
        XCTAssertEqual(controller.activeSessionID, sessionID)
        XCTAssertTrue(SessionStore.shared.load(id: sessionID)?.messages.contains {
            $0.role == .user && $0.content == "Continue from the phone"
        } == true)

        let revoke = try await request(baseURL, path: "/api/revoke", method: "POST", token: token)
        XCTAssertEqual(revoke.status, 200)
        let afterRevoke = try await request(baseURL, path: "/api/status", token: token)
        XCTAssertEqual(afterRevoke.status, 401)
    }

    private struct HTTPResult {
        let status: Int
        let headers: [String: String]
        let body: String
        let json: LFJSONValue
    }

    private func request(
        _ baseURL: URL,
        path: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResult {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = 5
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
                headers[key.lowercased()] = value
            }
        }
        return HTTPResult(
            status: http.statusCode,
            headers: headers,
            body: String(decoding: data, as: UTF8.self),
            json: (try? LFJSONValue.decode(data)) ?? .null)
    }
}
