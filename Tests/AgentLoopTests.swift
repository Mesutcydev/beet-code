import XCTest
@testable import BeetCode

/// Deterministic AgentLoop tests driven by FakeLLMEngine — no model weights,
/// no Metal, no network.
final class AgentLoopTests: XCTestCase {

    private var workspace: TempWorkspace!
    private var engine: FakeLLMEngine!

    /// Three backticks (built without literal backticks in source).
    private let fence = "\u{60}\u{60}\u{60}"

    override func setUpWithError() throws {
        workspace = TempWorkspace()
        engine = FakeLLMEngine()
        // Capsules written by loop runs stay inside the temp workspace.
        TaskCapsuleStore.shared.overrideDirectory = workspace.url(for: "Capsules")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        workspace = nil
        engine = nil
    }

    private func toolCall(_ name: String, _ arguments: String) -> String {
        "\(fence)tool\n{\"name\": \"\(name)\", \"arguments\": \(arguments)}\n\(fence)"
    }

    private func makeLoop(
        config: AgentLoop.Configuration = AgentLoop.Configuration(),
        autoApproveEdits: Bool = false,
        autoApproveCommands: Bool = false
    ) -> AgentLoop {
        let permissions = PermissionGate(
            autoApproveEdits: autoApproveEdits,
            autoApproveCommands: autoApproveCommands,
            workspace: workspace!.workspace)
        return AgentLoop(
            engine: engine,
            workspace: workspace!.workspace,
            tools: [
                ReadFileTool(),
                WriteFileTool(),
                ListDirectoryTool(),
                SearchTool(),
                ApplyPatchTool(),
                RunCommandTool(),
            ],
            permissions: permissions,
            configuration: config)
    }

    @discardableResult
    private func runToCompletion(
        _ loop: AgentLoop,
        message: String = "task",
        timeout: TimeInterval = 10
    ) async -> EventCollector {
        let collector = EventCollector()
        let stream = await loop.run(userMessage: message)
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: timeout)
        _ = await collection
        XCTAssertNotNil(finish, "loop never finished")
        return collector
    }

    private func waitForApproval(_ collector: EventCollector) async -> ApprovalRequest? {
        let seen = await collector.waitUntil { events in
            events.contains { event in
                if case .awaitingApproval = event { return true }
                return false
            }
        }
        XCTAssertTrue(seen, "no approval was requested")
        return collector.approvals().first
    }

    // MARK: Basic flow

    func testPlainCompletionAndStreamClosure() async throws {
        engine.enqueue(.text("Done — nothing to do."))
        let loop = makeLoop()
        let collector = await runToCompletion(loop)
        XCTAssertEqual(collector.finish, .completed("Done — nothing to do."))
        XCTAssertEqual(collector.assistantMessages(), ["Done — nothing to do."])
        XCTAssertFalse(collector.tokenDeltas().isEmpty)
        XCTAssertTrue(collector.all.contains(.taskStarted))
    }

    func testReadToolAutoExecutesWithoutApproval() async throws {
        workspace!.write("hello world", to: "notes.txt")
        engine.enqueue(texts: [
            "Let me read it.\n" + toolCall("read_file", "{\"path\": \"notes.txt\"}"),
            "The file says hello world. Task complete.",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop)

        XCTAssertEqual(collector.toolCalls().map(\.name), ["read_file"])
        XCTAssertTrue(collector.approvals().isEmpty, "reads must never require approval")
        let finished = collector.events { event in
            if case .toolCallFinished(let invocation, let output, let failed) = event {
                return (invocation.name, output, failed)
            }
            return nil
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0].0, "read_file")
        XCTAssertFalse(finished[0].2)
        XCTAssertTrue(finished[0].1.contains("hello world"))
        XCTAssertEqual(collector.finish, .completed("The file says hello world. Task complete."))
    }

    func testTaskSubagentReturnsChildAnswerWithoutTouchingParentHistory() async throws {
        workspace!.write("hello from readme", to: "README.md")
        engine.enqueue(texts: [
            "Delegating.\n" + toolCall("task", "{\"prompt\": \"What does README.md say?\"}"),
            "The readme says hello from readme.",
            "Subagent finished. Task complete.",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop, timeout: 15)

        XCTAssertEqual(collector.toolCalls().map(\.name), ["task"])
        let finished = collector.events { event in
            if case .toolCallFinished(let invocation, let output, let failed) = event {
                return (invocation.name, output, failed)
            }
            return nil
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0].0, "task")
        XCTAssertFalse(finished[0].2, finished[0].1)
        XCTAssertTrue(finished[0].1.contains("hello from readme"), finished[0].1)
        XCTAssertEqual(collector.finish, .completed("Subagent finished. Task complete."))
        // Parent engine still holds the scripted FIFO — child used streamReplay,
        // so the third response belongs to the parent, not a stolen turn.
        XCTAssertGreaterThanOrEqual(engine.streamCallCount, 3)
    }

    func testTaskSubagentCanWriteWhenEditsAutoApproved() async throws {
        var config = AgentLoop.Configuration()
        config.checkpointingEnabled = false
        engine.enqueue(texts: [
            "Delegating write.\n" + toolCall("task", "{\"prompt\": \"create hello.txt\"}"),
            toolCall("write_file", "{\"path\": \"hello.txt\", \"content\": \"hello nested\"}"),
            "Created hello.txt.",
            "Subagent wrote the file.",
        ])
        let loop = makeLoop(config: config, autoApproveEdits: true)
        let collector = await runToCompletion(loop, timeout: 15)
        XCTAssertEqual(collector.finish, .completed("Subagent wrote the file."))
        let written = try String(
            contentsOf: workspace!.url.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(written, "hello nested")
    }

    // MARK: Reasoning-only replies (Qwythos-style hybrids)

    /// A reasoning model can spend the whole token budget inside its think
    /// channel, leaving NOTHING after think-stripping. One re-prompt is fair;
    /// a repeated reasoning-only reply must surface the reasoning as the
    /// answer — never loop silently to maxTurns ("the model never answers").
    func testReasoningOnlyReplySurfacesAfterOneReprompt() async throws {
        engine.enqueue(texts: [
            "<think>let me consider this carefully</think>",
            "<think>the answer is 42</think>",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop)

        let messages = collector.assistantMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("the answer is 42"), messages[0])
        XCTAssertTrue(messages[0].contains("reply budget"), messages[0])
        guard case .completed = collector.finish else {
            XCTFail("expected completion, got \(String(describing: collector.finish))")
            return
        }
        let notices = collector.events { event in
            if case .protocolError(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(notices.count, 1, "exactly one re-prompt before the fallback")
    }

    /// The fallback never re-parses the reasoning for tool calls: reasoning
    /// traces contain HYPOTHETICAL calls the model considered, not calls it
    /// committed to — executing them would be a safety bug.
    func testReasoningFallbackNeverExecutesHypotheticalToolCalls() async throws {
        workspace!.write("secret", to: "notes.txt")
        engine.enqueue(texts: [
            "<think>I could read notes.txt but I should not</think>",
            "<think>I would run " + toolCall("read_file", "{\"path\": \"notes.txt\"}") + " but instead: no.</think>",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop)

        XCTAssertTrue(collector.toolCalls().isEmpty, "reasoning fallback must never execute tools")
        XCTAssertEqual(collector.assistantMessages().count, 1)
    }

    /// A single reasoning-only reply still gets its one re-prompt chance;
    /// a normal answer afterwards completes without any fallback note.
    func testReasoningOnlyReplyThenNormalAnswerCompletesCleanly() async throws {
        engine.enqueue(texts: [
            "<think>hmm</think>",
            "Here is the answer.",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop)

        XCTAssertEqual(collector.finish, .completed("Here is the answer."))
        XCTAssertEqual(collector.assistantMessages(), ["Here is the answer."])
    }

    /// Long reasoning traces are capped at the tail so the bubble stays
    /// readable.
    func testReasoningFallbackCapsLongTraces() {
        let long = String(repeating: "x", count: 5000)
        let fallback = AgentLoop.reasoningFallback(long)
        XCTAssertTrue(fallback.contains("…"), "long traces keep the tail only")
        XCTAssertLessThan(fallback.count, 1800)
        XCTAssertTrue(fallback.hasSuffix(String(repeating: "x", count: 1600)))
    }

    func testExactSecondTurnHistorySequence() async throws {
        workspace!.write("content", to: "a.txt")
        let callText = toolCall("read_file", "{\"path\": \"a.txt\"}")
        engine.enqueue(texts: [
            "Let me read a.txt.\n" + callText,
            "OK, now I understand. Complete.",
        ])
        let loop = makeLoop()
        _ = await runToCompletion(loop)

        let history = engine.turnHistory
        XCTAssertEqual(history.count, 2, "exactly two generations")
        // Turn 1: system + user.
        XCTAssertEqual(history[0].map(\.role), [.system, .user])
        // Turn 2: the raw assistant tool-call turn, followed by the tool
        // result — nothing else.
        XCTAssertEqual(history[1].count, 2)
        XCTAssertEqual(history[1][0].role, .assistant)
        XCTAssertTrue(history[1][0].content.contains(callText), "assistant turn must carry the raw tool call")
        XCTAssertEqual(history[1][1].role, .tool)
        XCTAssertTrue(history[1][1].content.contains("content"))
    }

    // MARK: Approvals and checkpoints

    func testWriteApprovalAccepted() async throws {
        let repo = GitRepo(in: workspace!)
        workspace!.write("base", to: "base.txt")
        repo.commitAll(message: "base")
        engine.enqueue(texts: [
            toolCall("write_file", "{\"path\": \"new.txt\", \"content\": \"agent data\"}"),
            "Wrote the file. Complete.",
        ])
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "write new.txt")
        async let collection: Void = collector.start(stream)

        guard let request = await waitForApproval(collector) else { return }
        await loop.resolve(requestID: request.id, approved: true)

        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .completed("Wrote the file. Complete."))
        XCTAssertEqual(workspace!.read("new.txt"), "agent data")
        // A checkpoint must have been created before the write.
        XCTAssertEqual(collector.checkpoints().count, 1)
    }

    func testWriteApprovalDeclinedStops() async throws {
        let repo = GitRepo(in: workspace!)
        workspace!.write("base", to: "base.txt")
        repo.commitAll(message: "base")
        engine.enqueue(.text(toolCall("write_file", "{\"path\": \"new.txt\", \"content\": \"x\"}")))
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "write new.txt")
        async let collection: Void = collector.start(stream)
        guard let request = await waitForApproval(collector) else { return }
        await loop.resolve(requestID: request.id, approved: false)
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .declined("User declined the requested action."))
        XCTAssertFalse(workspace!.exists("new.txt"), "declined write must not execute")
    }

    func testShellCommandApprovalAndCheckpointBeforeMutation() async throws {
        let repo = GitRepo(in: workspace!)
        workspace!.write("base", to: "base.txt")
        repo.commitAll(message: "base")
        engine.enqueue(texts: [
            toolCall("run_command", "{\"command\": \"touch created-by-agent.txt\"}"),
            "Done.",
        ])
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "create a file")
        async let collection: Void = collector.start(stream)
        guard let request = await waitForApproval(collector) else { return }
        XCTAssertTrue(request.invocation.summary.contains("touch created-by-agent.txt"))
        await loop.resolve(requestID: request.id, approved: true)
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .completed("Done."))
        // Potentially-mutating command: checkpoint must precede execution.
        XCTAssertEqual(collector.checkpoints().count, 1)
        XCTAssertTrue(workspace!.exists("created-by-agent.txt"))
    }

    func testCheckpointFailurePreventsMutation() async throws {
        // No git repository → checkpointing must refuse the mutation.
        engine.enqueue(texts: [
            toolCall("write_file", "{\"path\": \"new.txt\", \"content\": \"x\"}"),
            "The write was blocked. Complete.",
        ])
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "write new.txt")
        async let collection: Void = collector.start(stream)
        guard let request = await waitForApproval(collector) else { return }
        await loop.resolve(requestID: request.id, approved: true)
        let finish = await collector.waitForFinish()
        _ = await collection

        XCTAssertEqual(finish, .completed("The write was blocked. Complete."))
        XCTAssertFalse(workspace!.exists("new.txt"), "mutation must not run when the checkpoint fails")
        let failures = collector.events { event in
            if case .checkpointFailed(let reason) = event { return reason }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("not a git repository"), failures[0])
    }

    // MARK: Control flow

    func testAskUserSuspendsAndResumes() async throws {
        engine.enqueue(texts: [
            toolCall("ask_user", "{\"question\": \"Which port?\"}"),
            "Port 8080 it is. Complete.",
        ])
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "ask me something")
        async let collection: Void = collector.start(stream)

        let gotQuestion = await collector.waitUntil { events in
            events.contains { event in
                if case .askUser = event { return true }
                return false
            }
        }
        XCTAssertTrue(gotQuestion)
        let questions = collector.questions()
        XCTAssertEqual(questions.count, 1)
        let (requestID, question) = questions[0]
        XCTAssertEqual(question, "Which port?")

        // The wrong request ID must be a no-op.
        await loop.answerQuestion(requestID: UUID(), text: "ignored")
        XCTAssertEqual(collector.questions().count, 1, "wrong ID must not resolve the question")

        await loop.answerQuestion(requestID: requestID, text: "8080")
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .completed("Port 8080 it is. Complete."))
    }

    func testAttemptCompletionFinishes() async throws {
        engine.enqueue(.text(toolCall("attempt_completion", "{\"result\": \"Fixed the build.\"}")))
        let loop = makeLoop()
        let collector = await runToCompletion(loop)
        XCTAssertEqual(collector.finish, .completed("Fixed the build."))
        XCTAssertEqual(collector.assistantMessages(), ["Fixed the build."])
    }

    func testMultipleCallsAreProtocolErrorNotBatched() async throws {
        workspace!.write("a", to: "a.txt")
        workspace!.write("b", to: "b.txt")
        let callA = toolCall("read_file", "{\"path\": \"a.txt\"}")
        let callB = toolCall("read_file", "{\"path\": \"b.txt\"}")
        engine.enqueue(texts: [
            callA + " " + callB,
            "Sorry — one at a time. " + callA,
            "Done.",
        ])
        let loop = makeLoop()
        let collector = await runToCompletion(loop)

        let protocolErrors = collector.events { event in
            if case .protocolError(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(protocolErrors.count, 1)
        XCTAssertTrue(protocolErrors[0].contains("multiple tool calls"), protocolErrors[0])
        // Neither read was executed as a batch; the corrected single call ran.
        XCTAssertEqual(collector.toolCalls().count, 1)
        XCTAssertEqual(collector.toolCalls()[0].name, "read_file")
        XCTAssertEqual(collector.finish, .completed("Done."))
    }

    func testMaxTurnsTermination() async throws {
        engine.enqueue(texts: [
            toolCall("read_file", "{\"path\": \"missing.txt\"}"),
            toolCall("read_file", "{\"path\": \"missing.txt\"}"),
        ])
        var config = AgentLoop.Configuration()
        config.maxTurns = 2
        let loop = makeLoop(config: config)
        let collector = await runToCompletion(loop)
        XCTAssertEqual(collector.finish, .maxTurnsReached(2))
        XCTAssertEqual(engine.streamCallCount, 2)
    }

    // MARK: Cancellation

    func testCancellationDuringGeneration() async throws {
        engine.enqueue(.text("this will be cut off"))
        engine.holdNextStream()
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        async let collection: Void = collector.start(stream)

        // Wait until the generation is actually in flight.
        let deadline = Date().addingTimeInterval(5)
        while engine.streamCallCount < 1 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.streamCallCount, 1)
        await loop.cancel()
        engine.release()
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .cancelled, "cancellation must map to .cancelled, not completion")
        // cancel() signals the engine asynchronously; give it a moment.
        let cancelDeadline = Date().addingTimeInterval(5)
        while engine.cancelCallCount < 1 && Date() < cancelDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.cancelCallCount, 1)
    }

    func testCancellationDuringApproval() async throws {
        engine.enqueue(.text(toolCall("write_file", "{\"path\": \"new.txt\", \"content\": \"x\"}")))
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "write")
        async let collection: Void = collector.start(stream)
        guard let request = await waitForApproval(collector) else { return }
        _ = request
        await loop.cancel()
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .cancelled)
        XCTAssertFalse(workspace!.exists("new.txt"))
    }

    func testCancellationDuringToolExecution() async throws {
        // A FIFO makes `cat pipe` block forever — a policy-safe, read-only
        // command that runs until the process group is killed.
        _ = try ShellRunner.run(command: "mkfifo pipe", workingDirectory: workspace!.url, timeout: 5)
        engine.enqueue(texts: [
            toolCall("run_command", "{\"command\": \"cat pipe\"}"),
            "never reached",
        ])
        let loop = makeLoop(autoApproveCommands: true)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "run")
        async let collection: Void = collector.start(stream)
        let started = await collector.waitUntil { events in
            events.contains { event in
                if case .toolCallStarted = event { return true }
                return false
            }
        }
        XCTAssertTrue(started)
        await loop.cancel()
        let finish = await collector.waitForFinish(timeout: 15)
        _ = await collection
        XCTAssertEqual(finish, .cancelled, "cancel mid-command must still finish as .cancelled")
        // The shell process group must be dead.
        let probe = try ShellRunner.run(
            command: "pgrep -f 'cat pipe' || true",
            workingDirectory: workspace!.url,
            timeout: 5)
        XCTAssertFalse(probe.output.contains("cat"), "survivor: \(probe.output)")
    }

    func testReuseAfterCancellation() async throws {
        engine.enqueue(.text(toolCall("write_file", "{\"path\": \"new.txt\", \"content\": \"x\"}")))
        let loop = makeLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "write")
        async let collection: Void = collector.start(stream)
        _ = await waitForApproval(collector)
        await loop.cancel()
        _ = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(collector.finish, .cancelled)

        // The same loop instance must accept a fresh run (cancellation state
        // resets at run start).
        engine.enqueue(.text("second run complete"))
        let second = await runToCompletion(loop, message: "again")
        XCTAssertEqual(second.finish, .completed("second run complete"))
        XCTAssertTrue(second.all.contains(.taskStarted))
    }

    func testConcurrentRunRejected() async throws {
        engine.enqueue(.text("first run result"))
        let loop = makeLoop()
        let first = EventCollector()
        let stream1 = await loop.run(userMessage: "first")
        async let c1: Void = first.start(stream1)

        // Second run while the first is active: rejected immediately.
        let second = EventCollector()
        let stream2 = await loop.run(userMessage: "second")
        async let c2: Void = second.start(stream2)
        let secondFinish = await second.waitForFinish()
        _ = await c2
        guard case .engineError(let message)? = secondFinish else {
            return XCTFail("expected engineError, got \(String(describing: secondFinish))")
        }
        XCTAssertTrue(message.contains("already running"), message)

        // The first run is unaffected.
        let firstFinish = await first.waitForFinish()
        _ = await c1
        XCTAssertEqual(firstFinish, .completed("first run result"))
    }

    // MARK: Compaction

    func testCompactionPreservesAssistantToolPairing() async throws {
        workspace!.write("x", to: "a.txt")
        var responses: [String] = []
        for _ in 0..<5 {
            responses.append(toolCall("read_file", "{\"path\": \"a.txt\"}"))
        }
        responses.append("all done")
        engine.enqueue(texts: responses)

        var config = AgentLoop.Configuration()
        config.contextWindowTokens = 64  // tiny window forces compaction
        let loop = makeLoop(config: config)
        let collector = await runToCompletion(loop)
        XCTAssertEqual(collector.finish, .completed("all done"))

        let messages = await loop.sessionRecord.messages
        XCTAssertGreaterThan(messages.count, 6)
        // Ordering invariant: every toolResult is preceded (ignoring
        // toolCall bookkeeping) by its assistant turn — never by another
        // toolResult without an assistant between them.
        var pendingAssistant = false
        for message in messages {
            switch message.role {
            case .assistant:
                pendingAssistant = true
            case .toolResult:
                XCTAssertTrue(pendingAssistant, "toolResult without preceding assistant turn")
                pendingAssistant = false
            case .toolCall, .user, .system:
                break
            }
        }
        // Old tool outputs were stubbed, assistant turns were not.
        let stubbed = messages.filter { $0.content.contains("omitted") }
        XCTAssertGreaterThan(stubbed.count, 0)
        let assistantContents = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertFalse(assistantContents.contains { $0.contains("omitted") })
    }


    // MARK: Plan mode (v0.4)

    func testPlanModePresentsPlanBeforeAnyTool() async throws {
        workspace!.write("x", to: "a.txt")
        engine.enqueue(texts: [
            "My plan: read a.txt, then update it. Here is the plan text.",
            toolCall("read_file", "{\"path\": \"a.txt\"}"),
            "Done.",
        ])
        var config = AgentLoop.Configuration()
        config.planMode = true
        let loop = makeLoop(config: config)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "update a.txt")
        async let collection: Void = collector.start(stream)

        // The plan is proposed and NO tool has run.
        let gotPlan = await collector.waitUntil { events in
            events.contains { event in
                if case .planProposed = event { return true }
                return false
            }
        }
        XCTAssertTrue(gotPlan, "plan must be proposed")
        let plans = collector.events { event in
            if case .planProposed(let plan) = event { return plan }
            return nil
        }
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].contains("My plan"), plans[0])
        XCTAssertTrue(collector.toolCalls().isEmpty, "no tool may run before approval")

        // Approve → the loop proceeds to act.
        await loop.resolvePlan(approved: true)
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .completed("Done."))
        XCTAssertEqual(collector.toolCalls().map(\.name), ["read_file"])
    }

    func testPlanModeDeclineStops() async throws {
        engine.enqueue(.text("Plan: do nothing."))
        var config = AgentLoop.Configuration()
        config.planMode = true
        let loop = makeLoop(config: config)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        async let collection: Void = collector.start(stream)
        _ = await collector.waitUntil { events in
            events.contains { event in
                if case .planProposed = event { return true }
                return false
            }
        }
        await loop.resolvePlan(approved: false)
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .declined("The plan was not approved."))
        XCTAssertTrue(collector.toolCalls().isEmpty)
    }
    func testPlanModeRevisionFeedsBackAndReproposes() async throws {
        engine.enqueue(texts: [
            "Plan: first idea.",
            "Plan: second idea, revised.",
            "Done after approval.",
        ])
        var config = AgentLoop.Configuration()
        config.planMode = true
        let loop = makeLoop(config: config)
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "task")
        async let collection: Void = collector.start(stream)

        let first = await collector.waitUntil { events in
            events.contains { event in
                if case .planProposed(let plan) = event { return plan.contains("first") }
                return false
            }
        }
        XCTAssertTrue(first)

        // Revision: the feedback must reach the loop as a new user turn and
        // trigger a SECOND plan proposal — never be discarded.
        await loop.resolvePlanRevision(feedback: "Do it differently.")
        let second = await collector.waitUntil { events in
            events.filter {
                if case .planProposed = $0 { return true }
                return false
            }.count >= 2
        }
        XCTAssertTrue(second, "revision must re-enter plan mode")

        await loop.resolvePlan(approved: true)
        let finish = await collector.waitForFinish()
        _ = await collection
        XCTAssertEqual(finish, .completed("Done after approval."))
    }

    func testEngineFailureMapsToEngineError() async throws {
        engine.enqueue(.failure(FakeEngineTestError.simulated))
        let loop = makeLoop()
        let collector = await runToCompletion(loop)
        guard case .engineError(let message)? = collector.finish else {
            return XCTFail("expected engineError, got \(String(describing: collector.finish))")
        }
        XCTAssertTrue(message.contains("simulated engine failure"), message)
    }
}