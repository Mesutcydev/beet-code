import XCTest
@testable import BeetCode

/// LIVE end-to-end smoke test — NOT part of the hermetic suite contract.
/// Loads the real Qwythos GGUF through llama-server (exactly the app path:
/// GGUFEngine → RemoteLLMClient → AgentLoop) and runs a plan-mode turn with
/// a real file edit. Run manually:
///   xcodebuild test -scheme BeetCode -only-testing:BeetCodeTests/LiveSmokeTests
final class LiveSmokeTests: XCTestCase {

    func testPlanModeEditWithRealQwythos() async throws {
        // Opt-in only: the hermetic suite must never load real weights.
        // Run with BEETCODE_LIVE_SMOKE=1 in the environment.
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("live smoke is opt-in (BEETCODE_LIVE_SMOKE=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwythos-9B-Claude-Mythos-5-1M-MTP-Q5_K_M")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Qwythos model not installed")
        }

        let workspace = TempWorkspace()
        workspace.write("say hello to the world\n", to: "note.txt")

        // 1. Engine: real llama-server launch (MTP included when the header
        //    advertises it) through the real admission gate.
        let engine = GGUFEngine()
        let loadStart = Date()
        try await engine.load(
            directory: modelDir,
            modelID: "qwythos-smoke",
            diskBytes: 6_726_528_608)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print("[smoke] model loaded in \(String(format: "%.1f", loadSeconds))s")
        defer { Task { await engine.unload() } }

        // 2. Loop in PLAN mode — the exact user-reported broken path.
        var config = AgentLoop.Configuration()
        config.maxTurns = 8
        config.maxTokensPerTurn = 2048
        config.temperature = 0.6
        config.planMode = true
        config.checkpointingEnabled = false
        config.showReasoning = true
        let permissions = PermissionGate(
            autoApproveEdits: true,
            autoApproveCommands: false,
            workspace: workspace.workspace)
        let loop = AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool(), ApplyPatchTool()],
            permissions: permissions,
            configuration: config,
            modelID: "qwythos-smoke")

        // 3. Drive the event stream: approve the plan the moment it is
        //    proposed, record milestones, enforce a hard deadline.
        let milestones = Milestones()
        let stream = await loop.run(
            userMessage: "In note.txt, change the word hello to hi.")
        let consumer = Task {
            for await event in stream {
                switch event {
                case .planProposed(let plan):
                    await milestones.mark("planProposed")
                    print("[smoke] plan proposed (\(plan.count) chars) — approving")
                    await loop.resolvePlan(approved: true)
                case .toolCallStarted(let invocation):
                    await milestones.mark("tool:\(invocation.name)")
                    print("[smoke] tool started: \(invocation.name)")
                case .assistantMessage(let text):
                    await milestones.mark("assistantMessage")
                    print("[smoke] assistant message: \(text.prefix(120))")
                case .protocolError(let message):
                    print("[smoke] protocol notice: \(message.prefix(120))")
                case .finished(let reason):
                    await milestones.mark("finished:\(reason)")
                    print("[smoke] finished: \(reason)")
                default:
                    break
                }
            }
        }

        let deadline = Date().addingTimeInterval(220)
        while Date() < deadline {
            if await milestones.seen("finished:") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        if await !milestones.seen("finished:") {
            print("[smoke] deadline hit — cancelling")
            await loop.cancel()
        }
        _ = await consumer.result

        // 4. Assertions: the plan gate fired, the edit executed for real,
        //    and the run terminated without an engine error.
        let seen = await milestones.all
        XCTAssertTrue(seen.contains("planProposed"),
                      "plan mode must produce a plan card — milestones: \(seen)")
        let content = workspace.read("note.txt") ?? ""
        XCTAssertTrue(content.contains("hi"),
                      "the edit must land on disk — note.txt is: \(content)")
        XCTAssertTrue(seen.contains { $0.hasPrefix("finished:") },
                      "the run must finish — milestones: \(seen)")
        XCTAssertFalse(seen.contains("finished:engineError"),
                       "no engine error — milestones: \(seen)")
        let tools = seen.filter { $0.hasPrefix("tool:") }
        print("[smoke] PASS — tools used: \(tools)")
    }
}

/// Tiny async-safe milestone recorder for the smoke driver.
private actor Milestones {
    private var list: [String] = []
    func mark(_ value: String) { list.append(value) }
    func seen(_ prefix: String) -> Bool { list.contains { $0.hasPrefix(prefix) } }
    var all: [String] { list }
}
