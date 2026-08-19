import XCTest
@testable import BeetCode

/// Agent-loop integration of Workspace Intelligence: the provider's failure
/// modes, and the loop's per-task context injection driven by FakeLLMEngine.
final class IntelligenceIntegrationTests: XCTestCase {

    private var retained: [TempWorkspace] = []
    private var workspace: TempWorkspace!
    private var engine: FakeLLMEngine!

    private let fence = "\u{60}\u{60}\u{60}"

    override func setUpWithError() throws {
        workspace = TempWorkspace()
        retained.append(workspace)
        engine = FakeLLMEngine()
        TaskCapsuleStore.shared.overrideDirectory = workspace.url(for: "Capsules")
        workspace.write("""
        final class AuthService {
            func refreshToken() {
                persistSession()
            }

            private func persistSession() {
            }
        }
        """, to: "Sources/Auth/AuthService.swift")
        workspace.write("""
        final class SessionManager {
            func resume() {
                AuthService().refreshToken()
            }
        }
        """, to: "Sources/Auth/SessionManager.swift")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        IntelligenceStoreLayout.overrideRoot = nil
    }

    private func indexWorkspace() async throws {
        let storeDir = TempWorkspace()
        retained.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let intel = WorkspaceIntelligence(
            workspaceRoot: workspace.url, snapshotStore: snapshotStore)
        try await intel.index()
    }

    // MARK: Provider

    func testProviderIsNilWithoutIndex() {
        IntelligenceStoreLayout.overrideRoot = workspace.url(for: "no-stores")
        XCTAssertNil(IntelligenceContextProvider.section(
            workspaceRoot: workspace.url, task: "how does refreshToken work"))
    }

    func testProviderRendersAfterIndex() async throws {
        try await indexWorkspace()
        let section = IntelligenceContextProvider.section(
            workspaceRoot: workspace.url, task: "how does refreshToken work")
        XCTAssertNotNil(section)
        XCTAssertTrue(section?.contains("refreshToken") ?? false, section ?? "")
    }

    // MARK: Loop injection

    private func makeLoop(intelligence: Bool) -> AgentLoop {
        var config = AgentLoop.Configuration()
        config.intelligenceContext = intelligence
        let permissions = PermissionGate(
            autoApproveEdits: true, autoApproveCommands: true,
            workspace: workspace.workspace)
        return AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), ListDirectoryTool()],
            permissions: permissions,
            configuration: config)
    }

    func testLoopInjectsIntelligenceBlock() async throws {
        try await indexWorkspace()
        engine.enqueue(texts: [
            "\(fence)tool\n{\"name\": \"attempt_completion\", \"arguments\": {\"summary\": \"done\"}}\n\(fence)",
        ])
        let loop = makeLoop(intelligence: true)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "how does refreshToken work")
        await collector.start(stream)
        _ = await collector.waitForFinish()

        let firstTurns = await engine.turnHistory.first
        let userTurn = firstTurns?.last(where: { $0.role == .user })
        XCTAssertTrue(userTurn?.content.contains("<workspace_intelligence>") ?? false,
                      "user turn must carry the context block")
        XCTAssertTrue(userTurn?.content.contains("refreshToken") ?? false)
        XCTAssertTrue(userTurn?.content.hasSuffix("how does refreshToken work") ?? false,
                      "raw task text stays at the tail")
    }

    func testLoopSkipsInjectionWhenDisabled() async throws {
        try await indexWorkspace()
        engine.enqueue(texts: [
            "\(fence)tool\n{\"name\": \"attempt_completion\", \"arguments\": {\"summary\": \"done\"}}\n\(fence)",
        ])
        let loop = makeLoop(intelligence: false)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "how does refreshToken work")
        await collector.start(stream)
        _ = await collector.waitForFinish()

        let firstTurns = await engine.turnHistory.first
        let userTurn = firstTurns?.last(where: { $0.role == .user })
        XCTAssertEqual(userTurn?.content, "how does refreshToken work")
    }

    func testLoopWithoutIndexRunsUnchanged() async throws {
        IntelligenceStoreLayout.overrideRoot = workspace.url(for: "no-stores")
        engine.enqueue(texts: [
            "\(fence)tool\n{\"name\": \"attempt_completion\", \"arguments\": {\"summary\": \"done\"}}\n\(fence)",
        ])
        let loop = makeLoop(intelligence: true)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "plain task")
        await collector.start(stream)
        _ = await collector.waitForFinish()

        let firstTurns = await engine.turnHistory.first
        let userTurn = firstTurns?.last(where: { $0.role == .user })
        XCTAssertEqual(userTurn?.content, "plain task")
    }
}
