import Foundation

/// The agent orchestrator. Owns the loop:
///
///     generate → parse tool call → PermissionGate → (approval) → checkpoint
///              → ToolExecutor → observation → generate …
///
/// The UI observes events and answers interactive requests (approvals,
/// questions) through `resolve`; it never reaches into the loop's state.
actor AgentLoop {

    struct Configuration: Sendable {
        var maxTurns: Int = 40
        var maxTokensPerTurn: Int = 4096
        var temperature: Double = 0.6
        var checkpointingEnabled: Bool = true
        var contextWindowTokens: Int = 32_768
        var thermalTokenCeiling: Int?
        /// When true, successful edits trigger a build-diagnostics pass. The
        /// diagnostics command still runs through the normal approval path —
        /// never silently.
        var verifyAfterEdits: Bool = false
        /// Show chain-of-thought (think) blocks in the transcript (v0.3).
        var showReasoning: Bool = false
        /// Plan mode: the model must present a plan and the user must approve
        /// it before ANY tool executes (v0.4).
        var planMode: Bool = false
        /// Goal mode is the explicit long-running task vocabulary layered on
        /// top of plan mode. It gives the model the same contract when the
        /// mode is selected from the composer or `/goal`.
        var goalMode: Bool = false
        /// Long-term memory mode (v0.3).
        var memoryMode: MemoryMode = .off
        /// How aggressively old tool outputs are compacted (v0.3).
        var compressionLevel: CompressionLevel = .standard
        /// OpenCode-compatible agent profile prompt and identity. The
        /// controller resolves the selected profile before constructing the
        /// loop, so nested loops can stay fully native and deterministic.
        var agentName: String?
        var agentPrompt: String?
        /// Workspace intelligence injection: when the workspace has an
        /// intelligence index, each task message is prefixed with a bounded,
        /// labeled context block from the ContextCompiler. The visible
        /// transcript keeps the raw user text either way.
        var intelligenceContext: Bool = true
        /// Parent loops register the `task` tool. Nested subagents never do
        /// (no recursion).
        var allowSubagents: Bool = true
        /// Nested loops must not overwrite the parent's encrypted session.
        var persistSessions: Bool = true
        /// Nested read-only subagents cannot suspend on ask_user (no UI).
        var allowAskUser: Bool = true
    }

    // Dependencies
    private let engine: any LLMEngine
    private let workspace: Workspace
    private let executor: ToolExecutor
    private let permissionGate: PermissionGate
    private let checkpointer: GitCheckpointer
    private let configuration: Configuration
    private let commandPolicy: CommandPolicy
    private let memory: AgentMemory?
    private let taskHint: String
    private let hooks: HookRunner

    // Loop state
    private var systemPrompt: String
    private var sentTurnCount = 0
    private var history: [ChatTurn] = []
    private var record: SessionRecord
    private var pending: PendingRequest?
    private var cancelled = false
    private var isRunning = false
    private var hasFinished = false
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var phase: AgentPhase = .idle
    /// False until the first plan is approved: plan mode gates every reply
    /// (including revisions) until then.
    private var planApproved = false
    /// True when the most recent verification checks produced failures — used
    private var lastVerificationFailed = false

    private func setPhase(_ newPhase: AgentPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        eventContinuation?.yield(.phaseChanged(newPhase))
    }

    init(
        engine: any LLMEngine,
        workspace: Workspace,
        tools: [any AgentTool],
        permissions: PermissionGate,
        configuration: Configuration = Configuration(),
        commandPolicy: CommandPolicy = CommandPolicy(),
        modelID: String = "",
        sessionID: UUID = UUID(),
        seedRecord: SessionRecord? = nil,
        repoIndex: RepoIndex? = nil,
        memory: AgentMemory? = nil,
        taskHint: String = "",
        hooks: HookRunner? = nil
    ) {
        self.engine = engine
        self.workspace = workspace
        self.memory = memory
        self.taskHint = taskHint
        self.hooks = hooks ?? HookRunner.load(workspaceRoot: workspace.root)
        let projectPolicy = ProjectPolicy.load(workspaceRoot: workspace.root)
        var effectiveConfiguration = configuration
        if let plan = projectPolicy?.plan { effectiveConfiguration.planMode = plan }
        if let goal = projectPolicy?.goal { effectiveConfiguration.goalMode = goal }
        if let verifyAfterEdits = projectPolicy?.verifyAfterEdits {
            effectiveConfiguration.verifyAfterEdits = verifyAfterEdits
        }
        // Control tools are part of the prompt and the executor's registry,
        // but the loop intercepts them before execution ever happens.
        var availableTools = tools
        if let projectPolicy, projectPolicy.hasToolFilter {
            availableTools = availableTools.filter { projectPolicy.includesTool($0.name) }
        }
        var allTools = availableTools + [ControlTools.askUser, ControlTools.attemptCompletion]
        if effectiveConfiguration.allowSubagents,
           projectPolicy?.includesTool(ControlTools.task.name) ?? true {
            allTools.append(ControlTools.task)
        }
        if memory != nil, effectiveConfiguration.memoryMode != .off {
            if projectPolicy?.includesTool("memory_add") ?? true {
                allTools.append(MemoryAddTool())
            }
            if projectPolicy?.includesTool("memory_delete") ?? true {
                allTools.append(MemoryDeleteTool())
            }
        }
        let context = ToolContext(workspace: workspace)
        context.memory = memory
        self.executor = ToolExecutor(tools: allTools, context: context)
        var effectivePermissions = permissions
        effectivePermissions.openCodePermissions = permissions.openCodePermissions.merged(
            with: projectPolicy?.openCodePermissions ?? .empty)
        self.permissionGate = effectivePermissions
        self.checkpointer = GitCheckpointer(workspace: workspace)
        self.configuration = effectiveConfiguration
        self.commandPolicy = commandPolicy
        let memorySection = memory?.contextSection(
            mode: effectiveConfiguration.memoryMode,
            taskHint: taskHint)
        let projectInstructions = ProjectInstructions.section(workspaceRoot: workspace.root)
        let historySection = WorkspaceHistory.section(workspacePath: workspace.root.path)
        self.systemPrompt = PromptBuilder.systemPrompt(
            tools: allTools, workspace: workspace, repoIndex: repoIndex,
            memorySection: memorySection, projectInstructions: projectInstructions,
            projectPolicy: projectPolicy?.promptSection,
            workspaceHistory: historySection,
            agentPrompt: effectiveConfiguration.agentPrompt,
            planMode: effectiveConfiguration.planMode,
            goalMode: effectiveConfiguration.goalMode,
            contextWindowTokens: effectiveConfiguration.contextWindowTokens,
            responseReserveTokens: effectiveConfiguration.maxTokensPerTurn)
        (engine as? any NativeToolConfigurable)?.configureNativeTools(
            allTools.map { NativeToolSpec(tool: $0) })
        if let seed = seedRecord {
            // Continuation: resume an existing session instead of starting a
            // fresh record — history and checkpoints carry over.
            self.record = SessionRecord(
                id: seed.id,
                title: seed.title,
                createdAt: seed.createdAt,
                updatedAt: Date(),
                workspacePath: seed.workspacePath,
                modelID: seed.modelID.isEmpty ? modelID : seed.modelID,
                messages: seed.messages,
                checkpoints: seed.checkpoints)
        } else {
            self.record = SessionRecord(
                id: sessionID,
                title: "Session",
                createdAt: Date(),
                updatedAt: Date(),
                workspacePath: workspace.root.path,
                modelID: modelID,
                messages: [],
                checkpoints: [])
        }
    }

    // MARK: Public surface

    /// Runs a task to completion (or max turns). Events stream out; the loop
    /// suspends when user input is needed, resumed via `resolve`. A second
    /// run while one is active is rejected immediately (one actor, one task).
    func run(userMessage: String) -> AsyncStream<AgentEvent> {
        guard !isRunning else {
            return AsyncStream { continuation in
                continuation.yield(.finished(.engineError("A task is already running in this session.")))
                continuation.finish()
            }
        }

        isRunning = true
        cancelled = false
        hasFinished = false
        pending = nil
        executor.context.clearCancellation()
        setPhase(configuration.planMode ? .planning : .working)

        return AsyncStream { continuation in
            self.attach(continuation, userMessage: userMessage)
        }
    }

    /// Answers an approval request; no-op when nothing is pending or the ID
    /// does not match the pending request.
    func resolve(requestID: UUID, approved: Bool) {
        guard case .approval(let request, let continuation)? = pending, request.id == requestID else {
            return
        }
        pending = nil
        continuation.resume(returning: approved)
    }

    /// Supplies the answer to an `ask_user` question.
    func answerQuestion(requestID: UUID, text: String) {
        guard case .question(let id, _, let continuation)? = pending, id == requestID else { return }
        pending = nil
        continuation.resume(returning: text)
    }

    /// Approves (or rejects) the pending plan; no-op when none is pending.
    func resolvePlan(approved: Bool) {
        guard case .plan(_, let continuation)? = pending else { return }
        pending = nil
        continuation.resume(returning: approved ? .approve : .cancel)
    }

    /// Sends revision feedback on the pending plan; no-op when none is
    /// pending. The feedback becomes the next user turn so the model re-plans
    /// instead of silently dropping the text.
    func resolvePlanRevision(feedback: String) {
        guard case .plan(_, let continuation)? = pending else { return }
        pending = nil
        continuation.resume(returning: .revise(feedback))
    }

    /// Cancels the run. Engine cancellation is structured: the spawned task
    /// is retained on the actor and awaited by `finish`, so a cancellation
    /// can never race a later load/unload from another call site.
    func cancel() {
        cancelled = true
        executor.context.requestCancellation()
        // Unblock any pending interactive request as a decline.
        if case .approval(_, let continuation) = pending {
            pending = nil
            continuation.resume(returning: false)
        }
        if case .question(_, _, let continuation) = pending {
            pending = nil
            continuation.resume(returning: "(cancelled)")
        }
        if case .plan(_, let continuation) = pending {
            pending = nil
            continuation.resume(returning: .cancel)
        }
        engineCancelTask = Task { await engine.cancelGeneration() }
    }

    private var engineCancelTask: Task<Void, Never>?

    var sessionRecord: SessionRecord { record }

    // MARK: Stream plumbing

    private func attach(_ continuation: AsyncStream<AgentEvent>.Continuation, userMessage: String) {
        eventContinuation = continuation
        continuation.yield(.taskStarted)
        record.messages.append(
            SessionMessage(role: .user, content: userMessage, toolName: nil, timestamp: Date()))
        Task { await self.step(userMessage: userMessage) }
    }

    /// Every terminal path funnels through here: yields `.finished` exactly
    /// once and closes the stream so consumers' `for await` loops end.
    private func finish(_ reason: AgentFinish) {
        guard !hasFinished else { return }
        hasFinished = true
        isRunning = false
        setPhase(.finished)
        // Terminal snapshot: durable task state, never disposable cache.
        saveTaskCapsule()
        persist()
        hooks.runStop(reason: reason.hookReason)
        eventContinuation?.yield(.finished(reason))
        eventContinuation?.finish()
    }

    private func replacePending(_ newPending: PendingRequest) {
        // A stale pending request must never be silently replaced: resume it
        // first so no suspension leaks.
        if case .approval(_, let oldApproval) = pending {
            pending = nil
            oldApproval.resume(returning: false)
        }
        if case .question(_, _, let oldQuestion) = pending {
            pending = nil
            oldQuestion.resume(returning: "(cancelled)")
        }
        if case .plan(_, let oldPlan) = pending {
            pending = nil
            oldPlan.resume(returning: .cancel)
        }
        pending = newPending
    }

    // MARK: Loop

    private func step(userMessage: String) async {
        var turns = 0
        // Consecutive replies that were all reasoning and no answer. One
        // re-prompt is fair (the model may comply); a streak means the
        // reasoning chronically eats the whole token budget — surface it.
        var emptyReplyStreak = 0

        do {
            await engine.reset()
            sentTurnCount = 0
            history = [ChatTurn(role: .system, content: systemPrompt)]
            // Continuation: rebuild the model context from the seeded
            // transcript so a resumed session actually remembers itself.
            // Without this, every continued run started from amnesia — the
            // seed only restored the visible transcript, not the context.
            // Drop the LAST message: that is the new user message `attach`
            // just appended; it is re-added below.
            if record.messages.count > 1 {
                let seeded = Array(record.messages.dropLast())
                history.append(contentsOf: seeded.compactMap { message in
                    switch message.role {
                    case .user:
                        return ChatTurn(role: .user, content: message.content)
                    case .assistant:
                        return ChatTurn(role: .assistant, content: message.content)
                    case .reasoning:
                        // Reasoning is transcript history only. Replaying it
                        // would inflate context and can expose provider
                        // summaries back to a model that did not ask for them.
                        return nil
                    case .toolResult:
                        return ChatTurn(role: .tool, content: message.content)
                    case .system:
                        return ChatTurn(role: .system, content: message.content)
                    case .toolCall:
                        // The assistant turn carries the raw tool-call text.
                        return nil
                    }
                })
            }
            // Workspace intelligence: a bounded, labeled context block
            // compiled for THIS task message. Degrades to the raw message
            // whenever no index exists or compilation fails.
            var effectiveMessage = userMessage
            if configuration.intelligenceContext,
               let section = IntelligenceContextProvider.section(
                   workspaceRoot: workspace.root, task: userMessage) {
                effectiveMessage = """
                <workspace_intelligence>
                \(section)
                </workspace_intelligence>

                \(userMessage)
                """
            }
            history.append(ChatTurn(role: .user, content: effectiveMessage))
            // A resumed session may already contain large tool observations.
            // Compact before the first generation as well as after later tool
            // calls, so the initial plan/reply gets the same protection.
            await compactIfNeeded()

            while turns < configuration.maxTurns && !cancelled {
                turns += 1

                // 1. Generate. A provider can know a smaller effective
                // context than the catalog/app configuration (common with
                // local gateways and GGUF servers). Recover once from an
                // explicit context-length rejection instead of surfacing a
                // dead task that the user has to restart manually.
                let raw: String
                do {
                    raw = try await generate()
                } catch {
                    guard Self.isContextOverflow(error),
                          await recoverFromContextOverflow(error) else {
                        throw error
                    }
                    raw = try await generate()
                }
                // Cancellation arriving during generation must not be
                // reported as a successful completion.
                if cancelled { finish(.cancelled); return }
                let extractedReasoning = PromptBuilder.extractingThinking(raw)
                if configuration.showReasoning,
                   let think = extractedReasoning,
                   !think.isEmpty {
                    record.messages.append(
                        SessionMessage(role: .reasoning, content: think, toolName: nil, timestamp: Date()))
                    eventContinuation?.yield(.reasoning(think))
                }
                var visible = PromptBuilder.strippingThinking(raw)

                // 2. Parse tool calls.
                let calls = ToolParser.parse(visible)

                // 2t. A reply ending in an UNTERMINATED tool-call object
                // executed nothing — the token ceiling cut the JSON off
                // mid-call. Never show the raw fragment as an answer or
                // declare completion: hand the model a protocol observation
                // and let it re-emit a call that fits the budget.
                if calls.isEmpty, ToolParser.looksLikeToolCallFragment(visible) {
                    let notice = "error: malformed tool call — the JSON was cut off before it closed, so nothing was executed. "
                        + "Re-emit exactly one complete tool block. If you are writing a file, keep the content small enough to fit in one reply or build it up in several appends."
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: notice, toolName: "protocol", timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: notice))
                    eventContinuation?.yield(.protocolError(notice))
                    await compactIfNeeded()
                    continue
                }

                // 2z. Empty after thinking-stripping means the token ceiling
                // cut the generation off mid-thought — or the model answers
                // entirely inside its reasoning channel (Qwythos-style hybrids
                // do this under a tight budget). One re-prompt gives the model
                // a chance to answer directly; on a repeated reasoning-only
                // reply, surface the reasoning itself as the answer — looping
                // to maxTurns on an invisible reply reads as "the model never
                // answers".
                if calls.isEmpty, visible.isEmpty {
                    emptyReplyStreak += 1
                    if emptyReplyStreak >= 2,
                       let think = extractedReasoning,
                       !think.isEmpty {
                        // Never re-parse the reasoning for tool calls: it
                        // contains hypothetical calls the model considered,
                        // not calls it committed to.
                        visible = Self.reasoningFallback(think)
                    } else {
                        let notice = "error: empty reply — the token budget ran out before any answer or tool call. "
                            + "Reply now with the answer or exactly one tool block, without a reasoning section."
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: notice, toolName: "protocol", timestamp: Date()))
                        history.append(ChatTurn(role: .tool, content: notice))
                        eventContinuation?.yield(.protocolError(notice))
                        await compactIfNeeded()
                        continue
                    }
                } else {
                    emptyReplyStreak = 0
                }

                // 2a. Plan mode: replies are plans, not actions, until one
                // is approved. Strip tool blocks, present the plan, and wait
                // for approval before any tool may execute.
                if configuration.planMode, !planApproved {
                    let planText = Self.extractPlan(from: visible, calls: calls)
                    record.messages.append(
                        SessionMessage(role: .assistant, content: planText, toolName: nil, timestamp: Date()))
                    setPhase(.awaitingPlanApproval)
                    eventContinuation?.yield(.planProposed(planText))
                    let decision = await requestPlanApproval(planText)
                    if cancelled { finish(.cancelled); return }
                    switch decision {
                    case .cancel:
                        finish(.declined("The plan was not approved."))
                        return
                    case .revise(let feedback):
                        // The feedback becomes the next user turn; the loop
                        // re-plans instead of silently discarding the text.
                        record.messages.append(
                            SessionMessage(role: .user, content: feedback, toolName: nil, timestamp: Date()))
                        history.append(ChatTurn(role: .assistant, content: planText))
                        history.append(ChatTurn(role: .user, content: feedback))
                        setPhase(.planning)
                        continue
                    case .approve:
                        planApproved = true
                        setPhase(.working)
                        // Approved: the plan becomes an assistant turn in the
                        // model context so the acting turn builds on it.
                        history.append(ChatTurn(role: .assistant, content: planText))
                        continue
                    }
                }


                if calls.isEmpty {
                    // Verification-before-completion for final prose too.
                    if configuration.verifyAfterEdits, lastVerificationFailed {
                        // Pair the refusal with the assistant claim it
                        // answers, keeping the transcript well-formed.
                        record.messages.append(
                            SessionMessage(role: .assistant, content: visible, toolName: nil, timestamp: Date()))
                        history.append(ChatTurn(role: .assistant, content: visible))
                        let notice = "error: the task looks complete, but the verification checks are still failing. "
                            + "Address the diagnostics before declaring success."
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: notice, toolName: "verification", timestamp: Date()))
                        history.append(ChatTurn(role: .tool, content: notice))
                        eventContinuation?.yield(.protocolError(notice))
                        continue
                    }
                    record.messages.append(
                        SessionMessage(role: .assistant, content: visible, toolName: nil, timestamp: Date()))
                    eventContinuation?.yield(.assistantMessage(visible))
                    rememberCompletion(summary: visible)
                    finish(.completed(visible))
                    return
                }

                // 3. Record the raw assistant turn (including the tool call)
                // in the transcript and the model context. It precedes every
                // tool observation so assistant/tool pairing is preserved.
                record.messages.append(
                    SessionMessage(role: .assistant, content: visible, toolName: nil, timestamp: Date()))
                history.append(ChatTurn(role: .assistant, content: visible))

                // 3a. One tool call per reply. Multiple calls are a
                // structured protocol error observation, never a bundled
                // batch.
                if calls.count > 1 {
                    let names = calls.map(\.name).joined(separator: ", ")
                    let error = "error: protocol violation — multiple tool calls in one reply (\(names)). "
                        + "Emit exactly one tool block per message, wait for its result, then continue."
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: error, toolName: "protocol", timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: error))
                    eventContinuation?.yield(.protocolError(error))
                    await compactIfNeeded()
                    continue
                }

                var call = calls[0]

                // 3b. Control-flow pseudo-tools handled by the loop itself.
                if call.name == "attempt_completion" {
                    let summary = call.string("result") ?? call.string("summary") ?? "Task complete."
                    // Verification-before-completion: with verification enabled,
                    // a completion claim while the last build still fails is
                    // refused — the diagnostics are fed back instead.
                    if configuration.verifyAfterEdits, lastVerificationFailed {
                        let notice = "error: completion claimed, but the verification checks are still failing. "
                            + "Address the diagnostics from the previous build before completing."
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: notice, toolName: "verification", timestamp: Date()))
                        history.append(ChatTurn(role: .tool, content: notice))
                        eventContinuation?.yield(.protocolError(notice))
                        continue
                    }
                    record.messages.append(
                        SessionMessage(role: .assistant, content: summary, toolName: nil, timestamp: Date()))
                    eventContinuation?.yield(.assistantMessage(summary))
                    rememberCompletion(summary: summary)
                    finish(.completed(summary))
                    return
                }
                if call.name == "ask_user" {
                    if !configuration.allowAskUser {
                        let observation = "error: ask_user is not available inside a subagent — answer with what you have or call attempt_completion"
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: observation, toolName: call.name, timestamp: Date()))
                        history.append(ChatTurn(role: .tool, content: observation))
                        await compactIfNeeded()
                        continue
                    }
                    let question = call.string("question") ?? "Please answer."
                    let answer = await askUser(question)
                    if cancelled { finish(.cancelled); return }
                    setPhase(.working)
                    let observation = "User answered: \(answer)"
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: observation, toolName: call.name, timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: observation))
                    await compactIfNeeded()
                    continue
                }
                if call.name == "task" {
                    let prompt = call.string("prompt") ?? ""
                    let role = SubagentRole.resolve(call.string("role") ?? call.string("agent"))
                    let invocation = ToolInvocation(
                        call: call,
                        summary: "\(role.displayName) subagent: \(prompt.prefix(72))")
                    eventContinuation?.yield(.toolCallStarted(invocation))
                    let observation: String
                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        observation = "error: task requires a prompt"
                    } else {
                        observation = await runSubagent(prompt: prompt, role: role)
                    }
                    if cancelled { finish(.cancelled); return }
                    eventContinuation?.yield(.toolCallFinished(
                        invocation, output: observation, failed: observation.hasPrefix("error:")))
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: observation, toolName: call.name, timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: observation))
                    await compactIfNeeded()
                    continue
                }

                // 3c. Permission gate.
                let invocation = ToolInvocation(call: call, summary: invocationSummary(call))
                eventContinuation?.yield(.toolCallStarted(invocation))
                record.messages.append(
                    SessionMessage(
                        role: .toolCall, content: call.argumentsJSON,
                        toolName: call.name, timestamp: Date()))

                let risk = executor.tool(named: call.name)?.risk
                switch permissionGate.decision(for: call, risk: risk) {
                case .denied(let reason):
                    let message = "denied by OpenCode permission: \(reason)"
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: message, toolName: call.name, timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: message))
                    eventContinuation?.yield(.toolCallFinished(invocation, output: message, failed: true))
                    await compactIfNeeded()
                    continue
                case .needsApproval:
                    guard await requestApproval(for: call, invocation: invocation) != nil else {
                        if cancelled { finish(.cancelled); return }
                        let declined = "declined by user"
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: declined, toolName: call.name, timestamp: Date()))
                        eventContinuation?.yield(.toolCallFinished(invocation, output: declined, failed: true))
                        finish(.declined("User declined the requested action."))
                        return
                    }
                    // Approved: back to work.
                    setPhase(.working)
                case .auto:
                    break
                }

                // 3c½. PreToolUse hooks may deny or rewrite arguments.
                // They cannot skip the permission gate above.
                switch hooks.runPreToolUse(tool: call.name, arguments: call.arguments) {
                case .allow:
                    break
                case .deny(let reason):
                    let message = "denied by hook: \(reason)"
                    record.messages.append(
                        SessionMessage(role: .toolResult, content: message, toolName: call.name, timestamp: Date()))
                    history.append(ChatTurn(role: .tool, content: message))
                    eventContinuation?.yield(.toolCallFinished(invocation, output: message, failed: true))
                    await compactIfNeeded()
                    continue
                case .rewrite(let next):
                    call = ParsedToolCall(name: call.name, arguments: next, index: call.index)
                }

                // 3d. Checkpoint immediately before any approved mutation
                // (writes and potentially-mutating commands).
                if configuration.checkpointingEnabled, isMutation(risk: risk, call: call) {
                    do {
                        let checkpoint = try checkpointer.snapshot(
                            summary: "before \(call.name) on turn \(turns)")
                        record.checkpoints.append(checkpoint)
                        eventContinuation?.yield(.checkpointCreated(checkpoint))
                    } catch {
                        // Surface the failure and do NOT execute the mutation:
                        // an action that cannot be undone must not run.
                        let message = "error: checkpoint failed — \(error.localizedDescription). "
                            + "The action was not executed."
                        record.messages.append(
                            SessionMessage(role: .toolResult, content: message, toolName: call.name, timestamp: Date()))
                        history.append(ChatTurn(role: .tool, content: message))
                        eventContinuation?.yield(.checkpointFailed(error.localizedDescription))
                        eventContinuation?.yield(.toolCallFinished(invocation, output: message, failed: true))
                        await compactIfNeeded()
                        continue
                    }
                }

                // 3e. Execute.
                let result = await executor.execute(call)
                hooks.runPostToolUse(
                    tool: call.name, arguments: call.arguments,
                    output: result.output, failed: result.failed)
                eventContinuation?.yield(.toolCallFinished(invocation, output: result.output, failed: result.failed))
                record.messages.append(
                    SessionMessage(role: .toolResult, content: result.output, toolName: call.name, timestamp: Date()))
                history.append(ChatTurn(role: .tool, content: result.output))

                // 3f. Optional post-edit verification: after a successful
                // mutating action, run build diagnostics through the same
                // approval path (never silently).
                if configuration.verifyAfterEdits,
                    !result.failed,
                    isMutation(risk: risk, call: call),
                    !cancelled
                {
                    await runVerificationChecks()
                }

                if cancelled { finish(.cancelled); return }
                await compactIfNeeded()
            }

            if cancelled {
                finish(.cancelled)
            } else {
                finish(.maxTurnsReached(configuration.maxTurns))
            }
        } catch {
            if cancelled {
                finish(.cancelled)
            } else {
                finish(.engineError(error.localizedDescription))
            }
        }
    }

    /// One model generation: sends only unsent turns.
    private func generate() async throws -> String {
        let unsent = Array(history[sentTurnCount...])
        sentTurnCount = history.count

        var result = ""
        let maxTokens = configuration.thermalTokenCeiling.map {
            min(configuration.maxTokensPerTurn, $0)
        } ?? configuration.maxTokensPerTurn
        let stream = engine.stream(
            adding: unsent,
            maxTokens: maxTokens,
            temperature: configuration.temperature)
        for try await chunk in stream {
            result += chunk
            eventContinuation?.yield(.tokenDelta(chunk))
        }
        return result
    }

    /// Context errors are recoverable only when the provider gives us a
    /// recognizable signal. Authentication, transport, and malformed-request
    /// failures must still surface immediately instead of being retried as if
    /// they were a sizing problem.
    private static func isContextOverflow(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("context") && (
            text.contains("exceed") ||
            text.contains("too long") ||
            text.contains("maximum") ||
            text.contains("length") ||
            text.contains("tokens")
        )
    }

    /// Applies a more conservative, provider-reported context budget and
    /// rebuilds the engine replay state. This is deliberately one bounded
    /// recovery pass; repeated retries would hide a broken gateway or a bad
    /// model template.
    private func recoverFromContextOverflow(_ error: Error) async -> Bool {
        let reportedLimit = Self.contextLimit(in: error)
        let targetWindow = min(
            configuration.contextWindowTokens,
            reportedLimit ?? configuration.contextWindowTokens)
        let compacted = ContextCompactor.compact(
            record.messages,
            keepRecent: 1,
            maxToolResultChars: 2_000)
        let fitted = ContextCompactor.fit(
            compacted,
            systemPrompt: systemPrompt,
            windowTokens: targetWindow,
            responseReserve: configuration.maxTokensPerTurn)

        // If the provider did not disclose a smaller limit and fitting made no
        // progress, a retry would be identical and only waste a turn.
        guard fitted != record.messages || targetWindow < configuration.contextWindowTokens else {
            return false
        }

        let activeUserTurn: ChatTurn? = {
            guard let last = history.last, last.role == .user,
                  last.content != fitted.last?.content else { return nil }
            return last
        }()
        record.messages = fitted
        rebuildHistory(from: fitted, replacingLastUserWith: activeUserTurn)
        sentTurnCount = 0
        await engine.reset()
        saveTaskCapsule()
        return true
    }

    /// The most common provider wording is “request (N tokens) exceeds the
    /// available context size (M tokens)”. Keep this parser tolerant of
    /// gateways that use “maximum context length” instead.
    private static func contextLimit(in error: Error) -> Int? {
        let text = error.localizedDescription.lowercased()
        let markers = [
            "available context size",
            "maximum context length",
            "context window",
            "context size"
        ]
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let suffix = text[range.upperBound...]
            let digits = suffix.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            if let value = Int(digits), value > 0 { return value }
        }
        return nil
    }

    /// Rebuilds model-facing history from the durable transcript while keeping
    /// the current task's enriched intelligence block in the active user turn.
    private func rebuildHistory(
        from messages: [SessionMessage],
        replacingLastUserWith activeUserTurn: ChatTurn?
    ) {
        history = [ChatTurn(role: .system, content: systemPrompt)]
        history.append(contentsOf: messages.compactMap { message in
            switch message.role {
            case .user:
                return ChatTurn(role: .user, content: message.content)
            case .assistant:
                return ChatTurn(role: .assistant, content: message.content)
            case .reasoning:
                return nil
            case .toolResult:
                return ChatTurn(role: .tool, content: message.content)
            case .system:
                return ChatTurn(role: .system, content: message.content)
            case .toolCall:
                return nil
            }
        })
        if let activeUserTurn,
           let index = history.lastIndex(where: { $0.role == .user }) {
            history[index] = activeUserTurn
        }
    }

    /// Runs the configured verification checks after an edit, through the
    /// same permission gate as any other command. Declined or failed
    /// verifications are observations, not crashes.
    private func runVerificationChecks() async {
        setPhase(.verifying)
        let call = ParsedToolCall(name: "build_diagnostics", arguments: .object([:]), index: 0)
        let invocation = ToolInvocation(call: call, summary: "Run build diagnostics after edit")
        eventContinuation?.yield(.toolCallStarted(invocation))
        record.messages.append(
            SessionMessage(role: .toolCall, content: call.argumentsJSON, toolName: call.name, timestamp: Date()))

        switch permissionGate.decision(for: call, risk: .execute) {
        case .denied(let reason):
            let message = "verification denied by OpenCode permission: \(reason)"
            eventContinuation?.yield(.toolCallFinished(invocation, output: message, failed: true))
            record.messages.append(
                SessionMessage(role: .toolResult, content: message, toolName: call.name, timestamp: Date()))
            setPhase(.working)
            return
        case .needsApproval:
            guard await requestApproval(for: call, invocation: invocation) != nil else {
                let declined = "verification checks declined by user"
                eventContinuation?.yield(.toolCallFinished(invocation, output: declined, failed: true))
                record.messages.append(
                    SessionMessage(role: .toolResult, content: declined, toolName: call.name, timestamp: Date()))
                setPhase(.working)
                return
            }
            setPhase(.verifying)
        case .auto:
            break
        }
        let result = await executor.execute(call)
        lastVerificationFailed = result.failed
        eventContinuation?.yield(.toolCallFinished(invocation, output: result.output, failed: result.failed))
        record.messages.append(
            SessionMessage(role: .toolResult, content: result.output, toolName: call.name, timestamp: Date()))
        history.append(ChatTurn(role: .tool, content: result.output))
        setPhase(.working)
    }
    /// Whether the tool call mutates the workspace, meaning an approved
    /// action needs a checkpoint before it runs.
    private func isMutation(risk: ToolRisk?, call: ParsedToolCall) -> Bool {
        switch risk {
        case .write:
            return true
        case .execute:
            if let command = call.string("command") {
                return commandPolicy.isPotentiallyMutating(command)
            }
            return true
        case .read, .none:
            return false
        }
    }

    /// Keeps transcripts within the context window by collapsing old tool
    /// outputs. If prose history alone is still too large, the compactor
    /// keeps the objective plus the newest work and inserts an omission
    /// marker instead of allowing a provider-side context 400.
    private func compactIfNeeded() async {
        let messages = record.messages
        let estimate = ContextCompactor.estimate(
            messages: messages,
            windowTokens: configuration.contextWindowTokens)
        let request = ContextCompactor.estimateRequest(
            messages: messages,
            systemPrompt: systemPrompt,
            windowTokens: configuration.contextWindowTokens,
            responseReserve: configuration.maxTokensPerTurn)
        // Compact against the whole request, not only the persisted messages:
        // system instructions and native/text tool protocol can consume a
        // meaningful part of a remote provider's context window.
        let compacted = ContextCompactor.compact(
            messages,
            keepRecent: configuration.compressionLevel.keepRecent,
            maxToolResultChars: configuration.compressionLevel.maxToolResultChars)
        let fitted = ContextCompactor.fit(
            compacted,
            systemPrompt: systemPrompt,
            windowTokens: configuration.contextWindowTokens,
            responseReserve: configuration.maxTokensPerTurn)
        guard estimate.shouldCompact || request.shouldCompact || fitted != messages else { return }

        // Keep the per-task intelligence block in the active model history;
        // the persisted session intentionally stores the clean user message.
        let activeUserTurn: ChatTurn? = {
            guard let last = history.last, last.role == .user,
                  last.content != messages.last?.content else { return nil }
            return last
        }()

        record.messages = fitted
        history = [ChatTurn(role: .system, content: systemPrompt)]
        history.append(contentsOf: fitted.compactMap { message in
            switch message.role {
            case .user:
                return ChatTurn(role: .user, content: message.content)
            case .assistant:
                return ChatTurn(role: .assistant, content: message.content)
            case .reasoning:
                return nil
            case .toolResult:
                return ChatTurn(role: .tool, content: message.content)
            case .system:
                return ChatTurn(role: .system, content: message.content)
            case .toolCall:
                // The assistant turn carries the raw tool-call text.
                return nil
            }
        })
        if let activeUserTurn,
           let index = history.lastIndex(where: { $0.role == .user }) {
            history[index] = activeUserTurn
        }
        sentTurnCount = 0
        await engine.reset()
        // Epoch boundary: persist the durable task capsule so agent progress
        // survives any termination — this is deliberate state, not cache.
        saveTaskCapsule()
        Log.agent.info("Compacted transcript from \(request.totalTokens) estimated request tokens")
    }

    /// Deterministically extracts the durable continuation state (changed
    /// files, diagnostics, checks, objective) and persists it OUTSIDE the
    /// caches tree. Nothing here is disposable.
    private func saveTaskCapsule() {
        var changed: [String] = []
        var diagnostics: [String] = []
        var checks: [String] = []
        for message in record.messages where message.role == .toolResult {
            guard let tool = message.toolName else { continue }
            switch tool {
            case "write_file", "apply_patch":
                if message.content.hasPrefix("wrote ") || message.content.hasPrefix("patched ") {
                    changed.append(message.content)
                }
            case "build_diagnostics":
                if message.content.hasPrefix("error:") || message.content.contains("[command exit") {
                    diagnostics.append(message.content)
                } else {
                    checks.append(message.content)
                }
            default:
                break
            }
        }
        let users = record.messages.filter { $0.role == .user }
        let capsule = AgentTaskCapsule(
            taskID: record.id,
            workspaceID: ContentDigest.sha256Hex(workspace.root.path),
            epochID: UUID(),
            objective: users.first?.content ?? record.title,
            changedFiles: changed,
            unresolvedDiagnostics: diagnostics,
            completedChecks: checks,
            lastUserInstruction: users.last?.content ?? "",
            createdAt: record.createdAt,
            updatedAt: Date())
        TaskCapsuleStore.shared.save(capsule)
    }

    /// Suspends until the user answers. Returns nil when declined/cancelled.
    private func requestApproval(for call: ParsedToolCall, invocation: ToolInvocation) async -> ApprovalRequest? {
        let tool = executor.tool(named: call.name)
        let preview = tool?.preview(call, in: executor.context) ?? .none
        let request = ApprovalRequest(id: UUID(), invocation: invocation, preview: preview)
        setPhase(.awaitingApproval)
        eventContinuation?.yield(.awaitingApproval(request))

        let approved: Bool = await withCheckedContinuation { continuation in
            replacePending(.approval(request, continuation))
        }
        return approved ? request : nil
    }

    /// Suspends until the user approves, revises, or rejects the proposed plan.
    private func requestPlanApproval(_ plan: String) async -> PlanDecision {
        return await withCheckedContinuation { continuation in
            replacePending(.plan(plan, continuation))
        }
    }

    private func askUser(_ question: String) async -> String {
        let requestID = UUID()
        setPhase(.awaitingQuestion)
        eventContinuation?.yield(.askUser(requestID, question))
        return await withCheckedContinuation { continuation in
            replacePending(.question(requestID, question, continuation))
        }
    }
    private func invocationSummary(_ call: ParsedToolCall) -> String {
        switch call.name {
        case "run_command":
            return call.string("command") ?? call.argumentsJSON
        case "read_file", "write_file", "apply_patch":
            return call.string("path") ?? call.argumentsJSON
        case "search":
            return call.string("pattern") ?? call.argumentsJSON
        default:
            return call.argumentsJSON
        }
    }

    /// Rule-based memory extraction on completion: stores a session summary
    /// and derives durable facts from the actions this run took.
    private func rememberCompletion(summary: String) {
        guard let memory, configuration.memoryMode != .off else { return }
        if configuration.memoryMode.includeSummaries {
            memory.addSummary(summary, sessionTitle: record.title)
        }
        if configuration.memoryMode.includeFacts {
            let actions = record.messages.compactMap { message -> String? in
                guard message.role == .toolResult, let tool = message.toolName else { return nil }
                switch tool {
                case "write_file", "apply_patch":
                    return Self.factFromEdit(message.content)
                default:
                    return nil
                }
            }
            for action in actions.prefix(8) {
                memory.addFact(action, source: "completion")
            }
        }
    }

    /// Plan mode: strip any tool blocks the model prefixed its plan with,
    /// so the user sees the plan text alone.
    private static func extractPlan(from visible: String, calls: [ParsedToolCall]) -> String {
        guard !calls.isEmpty else { return visible }
        var text = visible
        if let regex = try? NSRegularExpression(
            pattern: #"```[a-zA-Z0-9_-]*[ \t]*\n?([\s\S]*?)```"#) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? visible : trimmed
    }

    /// The reply to surface when a reasoning model spent its whole token
    /// budget on thinking and emitted no answer twice in a row. The TAIL of
    /// the reasoning carries the conclusions; a long trace is capped so the
    /// bubble stays readable.
    static func reasoningFallback(_ thinking: String) -> String {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 1600
        let tail = trimmed.count > cap
            ? "…" + trimmed.suffix(cap)
            : trimmed[...]
        return "*The model spent its whole reply budget on reasoning — here is what it worked out. "
            + "Raise “Max tokens per turn” in Settings for a full reply.*\n\n" + tail
    }

    private static func factFromEdit(_ output: String) -> String? {
        let patterns = [
            "wrote ",
            "patched ",
        ]
        for pattern in patterns where output.hasPrefix(pattern) {
            let path = output.dropFirst(pattern.count).split(separator: " ").first.map(String.init) ?? ""
            guard !path.isEmpty else { return nil }
            return pattern == "wrote " ? "created or rewrote \(path)" : "edited \(path)"
        }
        return nil
    }

    private func persist() {
        guard configuration.persistSessions else { return }
        record.updatedAt = Date()
        if record.title == "Session", let first = record.messages.first {
            record.title = String(first.content.prefix(60))
        }
        SessionStore.shared.save(record)
        SessionStore.shared.currentSessionID = record.id
    }

    /// Nested agent. Shares the parent's engine through IsolatedReplayEngine
    /// so the parent conversation is not reset. Writes and commands go
    /// through the same PermissionGate; approvals are forwarded to the
    /// parent UI. Role-specific tools keep read-only work read-only, while
    /// implementation children inherit the parent's verification setting.
    private func runSubagent(prompt: String, role: SubagentRole) async -> String {
        var childConfig = configuration
        childConfig.maxTurns = min(8, configuration.maxTurns)
        childConfig.planMode = false
        childConfig.verifyAfterEdits = role.runsProjectChecks && configuration.verifyAfterEdits
        childConfig.intelligenceContext = false
        childConfig.allowSubagents = false
        childConfig.persistSessions = false
        childConfig.allowAskUser = false
        childConfig.agentName = role.rawValue
        childConfig.agentPrompt = [
            configuration.agentPrompt,
            role.prompt,
        ].compactMap { $0 }.joined(separator: "\n\n")

        let childGate = PermissionGate(
            autoApproveEdits: permissionGate.autoApproveEdits,
            autoApproveCommands: permissionGate.autoApproveCommands,
            commandPolicy: commandPolicy,
            workspace: workspace,
            overrides: permissionGate.overrides,
            openCodePermissions: role.allowsWrites
                ? permissionGate.openCodePermissions
                : permissionGate.openCodePermissions.merged(with: OpenCodeCompatibility.OpenCodePermissionSet(rules: [
                    .init(action: "edit", resource: "*", effect: .deny),
                ])))

        let childTools: [any AgentTool]
        switch role {
        case .research:
            childTools = [
                ReadFileTool(),
                ListDirectoryTool(),
                SearchTool(),
                FindFilesTool(),
                FindFilesTool(name: "glob"),
            ]
        case .implement:
            childTools = [
                ReadFileTool(),
                WriteFileTool(),
                MoveFileTool(),
                ApplyPatchTool(),
                ListDirectoryTool(),
                SearchTool(),
                FindFilesTool(),
                FindFilesTool(name: "glob"),
                RunCommandTool(),
                BuildDiagnosticsTool(),
            ]
        case .verify, .review:
            childTools = [
                ReadFileTool(),
                ListDirectoryTool(),
                SearchTool(),
                FindFilesTool(),
                FindFilesTool(name: "glob"),
                RunCommandTool(),
                BuildDiagnosticsTool(),
            ]
        }

        let child = AgentLoop(
            engine: IsolatedReplayEngine(base: engine),
            workspace: workspace,
            tools: childTools,
            permissions: childGate,
            configuration: childConfig,
            commandPolicy: commandPolicy,
            modelID: record.modelID,
            sessionID: UUID(),
            taskHint: prompt)

        var lastAnswer = "(subagent produced no answer)"
        let stream = await child.run(userMessage: prompt)
        for await event in stream {
            if cancelled {
                await child.cancel()
                return "error: parent cancelled — subagent stopped"
            }
            switch event {
            case .awaitingApproval(let request):
                setPhase(.awaitingApproval)
                eventContinuation?.yield(.awaitingApproval(request))
                let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    replacePending(.approval(request, cont))
                }
                setPhase(.working)
                await child.resolve(requestID: request.id, approved: approved)
            case .checkpointCreated(let checkpoint):
                record.checkpoints.append(checkpoint)
                eventContinuation?.yield(.checkpointCreated(checkpoint))
            case .assistantMessage(let text) where !text.isEmpty:
                lastAnswer = text
            case .finished(.completed(let text)) where !text.isEmpty:
                lastAnswer = text
            case .finished(.declined(let detail)):
                return "error: subagent declined — \(detail)"
            case .finished(.engineError(let message)):
                return "error: subagent engine — \(message)"
            case .finished(.cancelled):
                return "error: subagent cancelled"
            default:
                break
            }
        }
        return "Subagent result:\n\(lastAnswer)"
    }
}
