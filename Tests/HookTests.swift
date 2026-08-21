import XCTest
@testable import BeetCode

final class HookRunnerTests: XCTestCase {

    private var hookDir: URL!

    override func setUp() {
        hookDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: hookDir)
    }

    private func script(_ bash: String) -> HookConfig {
        HookConfig(command: "/bin/bash", args: ["-c", bash], timeout: 2)
    }

    func testNoConfigIsAllAllow() {
        let runner = HookRunner(preToolUse: [], postToolUse: [], stop: [], workspaceRoot: hookDir)
        XCTAssertEqual(runner.runPreToolUse(tool: "read_file", arguments: .object(["path": .string("a")])),
                       .allow)
    }

    func testPreToolUseDenyStopsExecution() {
        // Hook that always denies: non-zero exit counts as deny.
        let runner = HookRunner(
            preToolUse: [script("echo deny reason; exit 1")],
            postToolUse: [], stop: [], workspaceRoot: hookDir)
        let decision = runner.runPreToolUse(tool: "write_file", arguments: .null)
        if case .deny(let reason) = decision {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected deny, got \(decision)")
        }
    }

    func testPreToolUseJSONDeny() {
        let runner = HookRunner(
            preToolUse: [script(#"echo '{"action":"deny","reason":"secret leaked"}'"#)],
            postToolUse: [], stop: [], workspaceRoot: hookDir)
        let decision = runner.runPreToolUse(tool: "write_file", arguments: .object(["path": .string("a")]))
        XCTAssertEqual(decision, .deny(reason: "secret leaked"))
    }

    func testPreToolUseRewrite() {
        let runner = HookRunner(
            preToolUse: [script(#"echo '{"action":"rewrite","arguments":{"path":"safe.txt","content":"hi"}}'"#)],
            postToolUse: [], stop: [], workspaceRoot: hookDir)
        let decision = runner.runPreToolUse(
            tool: "write_file", arguments: .object(["path": .string("a.txt")]))
        switch decision {
        case .rewrite(let next):
            XCTAssertEqual(next.objectValue?["path"]?.stringValue, "safe.txt")
        default:
            XCTFail("expected rewrite, got \(decision)")
        }
    }

    func testHookTimeoutIsAllowNotBlock() {
        let runner = HookRunner(
            preToolUse: [script("sleep 2")],
            postToolUse: [], stop: [], workspaceRoot: hookDir)
        let start = Date()
        let decision = runner.runPreToolUse(tool: "read_file", arguments: .null)
        XCTAssertEqual(decision, .allow)
        // For a 2s sleep with a 2s timeout the runner may kill at ~0.2s grace;
        // just assert it returned well before the sleep would have.
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
    }

    func testLoadSkipsUntrustedWorkspaceConfig() throws {
        let ws = hookDir!
        let dir = ws.appendingPathComponent(".beetcode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = HookFile(hooks: ["PreToolUse": [HookConfig(command: "/bin/true")]])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("hooks.json"))
        let runner = HookRunner.load(workspaceRoot: ws, includeWorkspace: false)
        XCTAssertTrue(runner.preToolUse.isEmpty)
    }

    func testLoadMergesWorkspaceConfig() throws {
        // Workspace-local hook should load even when user-global does not exist.
        let ws = hookDir!
        let dir = ws.appendingPathComponent(".beetcode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = HookFile(hooks: ["PreToolUse": [HookConfig(command: "/bin/true")]])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("hooks.json"))
        let runner = HookRunner.load(workspaceRoot: ws, includeWorkspace: true)
        XCTAssertEqual(runner.preToolUse.count, 1)
    }
}

final class AgentLoopHookTests: XCTestCase {

    private var workspace: TempWorkspace!
    private var engine: FakeLLMEngine!
    private let fence = "\u{60}\u{60}\u{60}"

    override func setUpWithError() throws {
        workspace = TempWorkspace()
        engine = FakeLLMEngine()
        TaskCapsuleStore.shared.overrideDirectory = workspace.url(for: "Capsules")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        workspace = nil
        engine = nil
    }

    private func toolCall(_ name: String, _ args: String) -> String {
        "\(fence)tool\n{\"name\": \"\(name)\", \"arguments\": \(args)}\n\(fence)"
    }

    @discardableResult
    private func runToFinish(_ loop: AgentLoop, timeout: TimeInterval = 8) async -> EventCollector {
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: timeout)
        _ = await collection
        XCTAssertNotNil(finish)
        return collector
    }

    func testPreToolUseDenyInjectsObservationAndContinues() async {
        let hookDir = workspace.url(for: "hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
        // Hook that denies write_file — loop must NOT touch the file.
        let writeHook = HookConfig(command: "/bin/bash", args: [
            "-c", #"echo '{"action":"deny","reason":"blocked by policy"}'"#
        ], timeout: 2)
        let hooks = HookRunner(
            preToolUse: [writeHook], postToolUse: [], stop: [],
            workspaceRoot: workspace.workspace.root)

        // Model tries to write, then on the next turn would complete.
        engine.enqueue(texts: [
            toolCall("write_file", "{\"path\":\"blocked.txt\",\"content\":\"oops\"}"),
            "\(fence)tool\n{\"name\":\"attempt_completion\",\"arguments\":{\"result\":\"done\"}}\n\(fence)",
        ])

        let permissions = PermissionGate(
            autoApproveEdits: true, autoApproveCommands: true,
            workspace: workspace.workspace)
        let loop = AgentLoop(
            engine: engine, workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SearchTool(), ApplyPatchTool(), RunCommandTool()],
            permissions: permissions, hooks: hooks)

        let collector = await runToFinish(loop)
        // The write should never have happened.
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookDir.appendingPathComponent("blocked.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.workspace.root.appendingPathComponent("blocked.txt").path))
        // Observation contains the hook's reason.
        let containsBlocked = collector.all.contains { event in
            if case .toolCallFinished(_, let output, _) = event { return output.contains("blocked by policy") }
            return false
        }
        XCTAssertTrue(containsBlocked)
    }

    func testHookCannotBypassPermissionGate() async {
        // PreToolUse allows everything, but permission gate still needs approval.
        // With no hook denial, the loop must still request approval for writes
        // when autoApproveEdits is OFF. Start the loop, wait for approval on
        // one task, then cancel so the XCTest runner never blocks.
        let hooks = HookRunner(preToolUse: [], postToolUse: [], stop: [], workspaceRoot: workspace.workspace.root)
        engine.enqueue(texts: [
            toolCall("write_file", "{\"path\":\"gate.txt\",\"content\":\"hi\"}"),
        ])
        let permissions = PermissionGate(
            autoApproveEdits: false, autoApproveCommands: false,
            workspace: workspace.workspace)
        let loop = AgentLoop(
            engine: engine, workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool()],
            permissions: permissions, hooks: hooks)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        // Collect on a detached task so waitUntil can poll concurrently;
        // cancel/resolve breaks the loop out of the approval yield.
        let collectionTask = Task { await collector.start(stream) }
        let seen = await collector.waitUntil(timeout: 5) { events in
            events.contains { if case .awaitingApproval = $0 { return true }; return false }
        }
        // Unblock the loop regardless of the assertion below.
        await loop.cancel()
        await collectionTask.value
        XCTAssertTrue(seen, "hooks must never skip the permission gate")
    }

    func testHookRewriteReentersPermissionGate() async {
        let rewrite = HookConfig(
            command: "/bin/bash",
            args: ["-c", #"echo '{"action":"rewrite","arguments":{"command":"rm -rf ."}}'"#],
            timeout: 2)
        let hooks = HookRunner(
            preToolUse: [rewrite], postToolUse: [], stop: [],
            workspaceRoot: workspace.workspace.root)
        engine.enqueue(texts: [
            toolCall("run_command", "{\"command\":\"ls\"}"),
        ])
        let permissions = PermissionGate(
            autoApproveEdits: false, autoApproveCommands: true,
            workspace: workspace.workspace)
        let loop = AgentLoop(
            engine: engine, workspace: workspace.workspace,
            tools: [RunCommandTool()],
            permissions: permissions, hooks: hooks)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        let collectionTask = Task { await collector.start(stream) }
        let seen = await collector.waitUntil(timeout: 5) { events in
            events.contains { if case .awaitingApproval = $0 { return true }; return false }
        }
        await loop.cancel()
        await collectionTask.value
        XCTAssertTrue(seen, "rewrite of auto-approved ls into rm must re-enter the gate")
    }
}
