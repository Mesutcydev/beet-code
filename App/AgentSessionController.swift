import Foundation
import SwiftUI

/// Bridges the AgentLoop actor to SwiftUI: consumes the event stream and
/// publishes transcript state. The UI talks only to this controller.
@MainActor
final class AgentSessionController: ObservableObject {

    struct TranscriptItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case assistant(String)
            case toolCall(ToolInvocation)
            case toolResult(id: UUID, output: String, failed: Bool, toolName: String?)
            case reasoning(String)
            case checkpoint(SessionCheckpoint)
            case notice(String)
        }

        let id: UUID
        var kind: Kind
    }

    @Published private(set) var transcript: [TranscriptItem] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var pendingApproval: ApprovalRequest?
    @Published private(set) var pendingQuestion: String?
    private var pendingQuestionID: UUID?
    @Published private(set) var pendingPlan: String?
    @Published private(set) var currentPhase: AgentPhase = .idle
    @Published private(set) var finishReason: AgentFinish?
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var gitOutput: String?
    private(set) var activeSessionID: UUID?

    private var loop: AgentLoop?
    private var eventTask: Task<Void, Never>?
    /// Live MCP servers for the current run; disconnected when it ends.
    private let mcpRegistry = MCPRegistry()
    /// Identifies the current run; events from a cancelled older run are
    /// rejected so they can never mutate a newer run's UI state.
    private var runID = UUID()
    /// Token deltas accumulate here and publish in ~30 ms batches: at local
    /// model speeds per-token publishing causes quadratic string copying and
    /// re-layout for no visible gain.
    private var pendingTokenBuffer = ""
    private var tokenFlushTask: Task<Void, Never>?

    /// Supplies the active model ID (AppState owns that truth).
    var activeModelIDHandler: () -> String = { "" }

    let engine: any LLMEngine
    private let settings: SettingsStore
    private let thermal: ThermalMonitor

    init(engine: any LLMEngine, settings: SettingsStore, thermal: ThermalMonitor) {
        self.engine = engine
        self.settings = settings
        self.thermal = thermal
    }

    // MARK: Task lifecycle

    func send(_ message: String, attachments: [ComposerAttachment] = [], seed: SessionRecord? = nil) {
        guard workspaceURL != nil, !isRunning else { return }

        // A stale event task must never outlive the run it belongs to.
        eventTask?.cancel()
        pendingApproval = nil
        pendingQuestion = nil
        pendingPlan = nil
        finishReason = nil

        Task { [weak self] in
            guard let self else { return }
            await self.startRun(message: message, attachments: attachments, seed: seed)
        }
    }

    /// The async half of `send`: connects MCP servers (bounded, best-effort)
    /// and then starts the loop with built-in + MCP tools merged.
    private func startRun(message: String, attachments: [ComposerAttachment], seed: SessionRecord?) async {
        guard let workspace = workspaceURL, !isRunning else { return }
        let workspaceScope = Workspace(root: workspace)

        // MCP: connect configured servers, collect their tools. Failures are
        // surfaced as notices but never block the run.
        let mcpResult = await mcpRegistry.start(workspaceRoot: workspace)
        for error in mcpResult.errors {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(error)))
        }
        if !mcpResult.connectedServers.isEmpty {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(
                "MCP servers connected: \(mcpResult.connectedServers.joined(separator: ", ")) (\(mcpResult.tools.count) tools)")))
        }
        let tools = Self.defaultTools + mcpResult.tools

        // Prepared turn: the transcript shows the user's clean message; the
        // MODEL receives bounded attachment context. The two never mix.
        let modelText = Self.expand(attachments: attachments, message: message)
        let displayText = attachments.isEmpty ? message : message + "  ·  " + Self.attachmentSummary(attachments)
        transcript.append(TranscriptItem(id: UUID(), kind: .user(displayText)))

        // Continuation seed: an explicit seed wins; otherwise the persisted
        // record for the ACTIVE session is resumed so restored and continued
        // sessions keep their history and checkpoints.
        let continuationSeed = seed ?? Self.persistedSeed(sessionID: activeSessionID, workspacePath: workspace.path)

        let autoApproveEdits = settings.autoApproveEdits
        let autoApproveCommands = settings.autoApproveCommands
        let maxTurns = settings.maxTurns
        let maxTokensPerTurn = settings.maxTokensPerTurn
        let temperature = settings.temperature
        let checkpointingEnabled = settings.checkpointingEnabled
        let showReasoning = settings.showReasoning
        let planMode = settings.planMode
        let permissions = PermissionGate(
            autoApproveEdits: autoApproveEdits,
            autoApproveCommands: autoApproveCommands,
            workspace: workspaceScope)

        // Long-term memory is per-workspace; built when the setting is on.

        // The session ID is decided HERE so undo/restore can find the
        // persisted record (the loop persists under this ID). A continuation
        // keeps the SAME id — never mint a fresh one on top of a restored
        // record, or undo would target a session that does not exist.
        let sessionID = continuationSeed?.id ?? seed?.id ?? UUID()
        activeSessionID = sessionID

        let agentLoop = AgentLoop(
            engine: engine,
            workspace: workspaceScope,
            tools: tools,
            permissions: permissions,
            configuration: AgentLoop.Configuration(
                maxTurns: maxTurns,
                maxTokensPerTurn: maxTokensPerTurn,
                temperature: temperature,
                checkpointingEnabled: checkpointingEnabled,
                thermalTokenCeiling: thermal.maxTokens(ceiling: maxTokensPerTurn),
                verifyAfterEdits: settings.verifyAfterEdits,
                showReasoning: showReasoning,
                planMode: planMode,
                memoryMode: settings.memoryMode,
                compressionLevel: settings.compressionLevel),
            modelID: activeModelIDHandler(),
            sessionID: sessionID,
            seedRecord: continuationSeed,
            repoIndex: RepoIndexer.build(root: workspace, taskHint: modelText),
            memory: settings.memoryMode == .off ? nil : AgentMemory(workspacePath: workspace.path),
            taskHint: modelText)
        loop = agentLoop
        isRunning = true
        let runToken = runID

        eventTask = Task { [weak self] in
            let stream = await agentLoop.run(userMessage: modelText)
            for await event in stream {
                guard let self else { return }
                self.handle(event, runID: runToken)
            }
            // The stream ended (possibly without .finished after a cancel):
            // never leave the UI stuck in a running state.
            self?.streamEnded(runID: runToken)
            // Teardown: MCP servers must not outlive the run that owns them.
            await self?.mcpRegistry.stop()
        }
    }

    func stop() {
        guard let loop else { return }
        Task { await loop.cancel() }
    }

    /// Switches the controller to a different workspace as ONE transaction:
    /// the active run fully stops first, interactive state is cleared, and the
    /// workspace's most recent session (if any) is restored. Undo and git
    /// controls then target the new project — never a stale checkpoint from
    /// the old one.
    func switchWorkspace(to url: URL) async {
        await stopAndWait()
        workspaceURL = url
        activeSessionID = nil
        gitOutput = nil
        transcript = []
        finishReason = nil
        streamingText = ""
        if let latest = SessionStore.shared.loadAll()
            .first(where: { $0.workspacePath == url.path }) {
            _ = restore(latest)
        }
    }

    /// Stops the active run and WAITS for the loop to reach its terminal
    /// state before returning. Engine transitions (load/unload/source swap)
    /// must await this so a generation can never outlive its model.
    func stopAndWait() async {
        guard let loop else {
            runID = UUID()
            return
        }
        self.loop = nil
        runID = UUID()
        await loop.cancel()
        // Bounded wait: the loop yields .finished and closes the stream on
        // cancellation; if that ever fails, the event task is force-cancelled.
        let deadline = Date().addingTimeInterval(5)
        while isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        eventTask?.cancel()
        eventTask = nil
        clearPending()
        isRunning = false
        dropTokenBuffer()
        streamingText = ""
    }

    /// The stream ended without a .finished event (cancel path): clear the
    /// run state ONLY if this is still the current run.
    private func streamEnded(runID token: UUID) {
        guard token == runID else { return }
        if loop != nil { loop = nil }
        eventTask = nil
        isRunning = false
        dropTokenBuffer()
        streamingText = ""
        clearPending()
    }

    private func clearPending() {
        pendingApproval = nil
        pendingQuestion = nil
        pendingQuestionID = nil
        pendingPlan = nil
    }

    /// Publishes buffered deltas. One scheduled flush per batch window; the
    /// final text always flushes immediately on message completion.
    private func scheduleTokenFlush() {
        guard tokenFlushTask == nil else { return }
        tokenFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            self.tokenFlushTask = nil
            self.flushTokens()
        }
    }

    private func flushTokens() {
        tokenFlushTask?.cancel()
        tokenFlushTask = nil
        guard !pendingTokenBuffer.isEmpty else { return }
        streamingText += pendingTokenBuffer
        pendingTokenBuffer = ""
    }

    /// Drops buffered deltas without publishing (run cleanup paths only).
    private func dropTokenBuffer() {
        tokenFlushTask?.cancel()
        tokenFlushTask = nil
        pendingTokenBuffer = ""
    }

    /// Turns attachments into part of the user message: files are quoted

    /// Restores a persisted session: validates its workspace binding, rebuilds
    /// the transcript from stored messages/checkpoints, and arms the session
    /// for continuation (the next send seeds the loop with this record).
    func restore(_ record: SessionRecord) -> Bool {
        guard SessionStore.shared.validateWorkspaceBinding(record) else { return false }
        // Cancel the actual loop, not just its consumer: a tool mid-flight
        // must not keep writing into a workspace we are leaving.
        let oldLoop = loop
        loop = nil
        eventTask?.cancel()
        eventTask = nil
        if let oldLoop {
            Task { await oldLoop.cancel() }
        }
        runID = UUID()
        isRunning = false
        pendingApproval = nil
        pendingQuestion = nil
        pendingQuestionID = nil
        pendingPlan = nil
        finishReason = nil
        dropTokenBuffer()
        streamingText = ""
        workspaceURL = URL(fileURLWithPath: record.workspacePath)

        var rebuilt: [TranscriptItem] = []
        for message in record.messages {
            switch message.role {
            case .user:
                rebuilt.append(TranscriptItem(id: UUID(), kind: .user(message.content)))
            case .assistant:
                rebuilt.append(TranscriptItem(id: UUID(), kind: .assistant(message.content)))
            case .toolCall:
                let call = ParsedToolCall(
                    name: message.toolName ?? "tool",
                    arguments: TolerantJSON.value(from: message.content) ?? .object([:]),
                    index: 0)
                let invocation = ToolInvocation(
                    call: call,
                    summary: Self.summary(for: message.toolName ?? "tool", content: message.content))
                rebuilt.append(TranscriptItem(id: UUID(), kind: .toolCall(invocation)))
            case .toolResult:
                rebuilt.append(
                    TranscriptItem(
                        id: UUID(),
                        kind: .toolResult(
                            id: UUID(), output: message.content,
                            failed: message.content.hasPrefix("error:") || message.content == "declined by user",
                            toolName: message.toolName)))
            case .system:
                break
            }
        }
        for checkpoint in record.checkpoints {
            rebuilt.append(TranscriptItem(id: UUID(), kind: .checkpoint(checkpoint)))
        }
        transcript = rebuilt
        // Remember the restored session as the current one.
        SessionStore.shared.currentSessionID = record.id
        activeSessionID = record.id
        return true
    }

    /// The transcript carries over; the next message continues the session
    /// with its compacted history and checkpoints.
    var restoredSeed: SessionRecord? {
        guard let id = SessionStore.shared.currentSessionID,
              let record = SessionStore.shared.load(id: id),
              record.workspacePath == workspaceURL?.path
        else { return nil }
        return record
    }

    private static func summary(for name: String, content: String) -> String {
        switch name {
        case "run_command":
            let value = TolerantJSON.value(from: content)?.objectValue?["command"]?.stringValue
            return value ?? content
        case "read_file", "write_file", "apply_patch":
            let value = TolerantJSON.value(from: content)?.objectValue?["path"]?.stringValue
            return value ?? content
        default:
            return content
        }
    }

    // MARK: Git controls (Phase 5)

    /// Runs a read-only git command in the workspace (UI-initiated, so no
    /// approval card is needed — the user's click IS the consent).
    func runGitCommand(_ command: String) {
        guard let workspace = workspaceURL else { return }
        gitOutput = "…running \(command)…"
        Task { [weak self] in
            let result = try? ShellRunner.run(
                command: command,
                workingDirectory: workspace,
                timeout: 15)
            await MainActor.run {
                guard let self else { return }
                self.gitOutput = result.map {
                    $0.timedOut ? "command timed out" : ($0.output.isEmpty ? "(no changes)" : $0.output)
                } ?? "git failed"
            }
        }
    }

    func gitStatus() { runGitCommand("git status --short") }
    func gitDiff() { runGitCommand("git diff --stat") }

    // MARK: Slash commands

    /// Executes a parsed slash command locally. Returns true when the input
    /// was consumed (the composer should not send it as a message).
    /// AppState supplies the model-switch callback; everything else runs on
    /// controller primitives only.
    var modelSwitchHandler: ((String) -> Void)?

    func handleSlash(_ text: String) -> Bool {
        guard let command = SlashCommand.parse(text) else { return false }
        switch command {
        case .plan:
            settings.planMode.toggle()
            notice("Plan mode \(settings.planMode ? "ON — the agent plans first, you approve before it acts." : "OFF — direct execution.")")

        case .undo:
            undoLastCheckpoint()

        case .compact:
            compactSessionNow()

        case .model(let id):
            if let handler = modelSwitchHandler {
                notice("Switching model to '\(id)'…")
                handler(id)
            } else {
                notice("Model switching is unavailable right now.")
            }

        case .memory:
            let facts = currentMemory()?.listFacts() ?? []
            if facts.isEmpty {
                notice("No stored facts for this workspace. Add one with /memory add <text>.")
            } else {
                let lines = facts.map { "• \($0.text)" }.joined(separator: "\n")
                notice("Workspace memory (\(facts.count) facts):\n\(lines)")
            }

        case .memoryAdd(let fact):
            if let memory = currentMemory() {
                _ = memory.addFact(fact, source: "user")
                notice("Stored fact: \(fact)")
            } else {
                notice("Memory is off — enable it in Settings → Agent → Memory first.")
            }

        case .help:
            notice(SlashCommand.helpText)

        case .unknown(let raw):
            notice("Unknown command '\(raw)'. Try /help.")
        }
        return true
    }

    /// Compresses the active session's history immediately and persists the
    /// result — the next send continues with the compacted record.
    private func compactSessionNow() {
        guard let id = activeSessionID,
              let record = SessionStore.shared.load(id: id),
              !record.messages.isEmpty
        else {
            notice("Nothing to compact.")
            return
        }
        let before = record.messages.count
        let level = settings.compressionLevel
        let compacted = ContextCompactor.compact(
            record.messages,
            keepRecent: level.keepRecent,
            maxToolResultChars: level.maxToolResultChars)
        var updated = record
        updated.messages = compacted
        updated.updatedAt = Date()
        SessionStore.shared.save(updated)
        notice("Compacted history: \(before) → \(compacted.count) messages (level: \(settings.compressionLevel.rawValue)).")
    }

    private func currentMemory() -> AgentMemory? {
        guard settings.memoryMode != .off, let workspace = workspaceURL else { return nil }
        return AgentMemory(workspacePath: workspace.path)
    }

    private func notice(_ text: String) {
        transcript.append(TranscriptItem(id: UUID(), kind: .notice(text)))
    }

    /// Restores the workspace to the most recent checkpoint. Surfaces the
    /// outcome in the transcript.
    func undoLastCheckpoint() {
        guard let workspace = workspaceURL else { return }
        let record: SessionRecord? = activeSessionID.flatMap { SessionStore.shared.load(id: $0) }
        guard let checkpoint = record?.checkpoints.last else {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice("No checkpoint to restore.")))
            return
        }
        do {
            try GitCheckpointer(workspace: Workspace(root: workspace)).restore(checkpoint)
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Restored checkpoint: \(checkpoint.summary)")))
        } catch {
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Undo failed: \(error.localizedDescription)")))
        }
    }
    // MARK: Plan approval

    func approvePlan() {
        guard pendingPlan != nil else { return }
        pendingPlan = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .notice("Plan approved — executing.")))
        if let loop {
            Task { await loop.resolvePlan(approved: true) }
        }
    }

    func revisePlan(_ feedback: String) {
        guard pendingPlan != nil else { return }
        pendingPlan = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .user(feedback)))
        if let loop {
            Task { await loop.resolvePlanRevision(feedback: feedback) }
        }
    }

    // MARK: Interactive responses

    func approve(_ approved: Bool) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        if approved {
            transcript.append(
                TranscriptItem(id: UUID(), kind: .notice("Approved: \(request.invocation.name)")))
        } else {
            transcript.append(
                TranscriptItem(id: UUID(), kind: .notice("Declined: \(request.invocation.name)")))
        }
        if let loop {
            Task { await loop.resolve(requestID: request.id, approved: approved) }
        }
    }

    func answerQuestion(_ text: String) {
        guard let requestID = pendingQuestionID, pendingQuestion != nil, !text.isEmpty else { return }
        pendingQuestion = nil
        pendingQuestionID = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .user(text)))
        if let loop {
            Task { await loop.answerQuestion(requestID: requestID, text: text) }
        }
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, runID token: UUID) {
        guard token == runID else { return }
        switch event {
        case .taskStarted:
            flushTokens()
            streamingText = ""

        case .tokenDelta(let chunk):
            pendingTokenBuffer += chunk
            scheduleTokenFlush()

        case .assistantMessage(let text):
            flushTokens()
            streamingText = ""
            transcript.append(TranscriptItem(id: UUID(), kind: .assistant(text)))

        case .toolCallStarted(let invocation):
            flushTokens()
            streamingText = ""
            transcript.append(TranscriptItem(id: UUID(), kind: .toolCall(invocation)))

        case .awaitingApproval(let request):
            pendingApproval = request

        case .toolCallFinished(let invocation, let output, let failed):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .toolResult(id: invocation.id, output: output, failed: failed, toolName: invocation.name)))

        case .askUser(let requestID, let question):
            pendingQuestionID = requestID
            pendingQuestion = question

        case .checkpointCreated(let checkpoint):
            transcript.append(
                TranscriptItem(id: UUID(), kind: .checkpoint(checkpoint)))

        case .checkpointFailed(let reason):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Checkpoint failed — the action was NOT executed: \(reason)")))

        case .protocolError(let message):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Tool protocol error: \(message)")))

        case .reasoning(let text):
            transcript.append(
                TranscriptItem(id: UUID(), kind: .reasoning(text)))

        case .planProposed(let plan):
            pendingPlan = plan

        case .phaseChanged(let phase):
            currentPhase = phase

        case .finished(let reason):
            flushTokens()
            streamingText = ""
            isRunning = false
            finishReason = reason
            clearPending()
            loop = nil
            eventTask = nil
        }
    }

    // MARK: Tool registry

    static let defaultTools: [any AgentTool] = [
        ReadFileTool(),
        WriteFileTool(),
        ListDirectoryTool(),
        SearchTool(),
        ApplyPatchTool(),
        RunCommandTool(),
        BuildDiagnosticsTool(),
        SimListDevicesTool(),
        SimBootDeviceTool(),
        SimLaunchAppTool(),
        SimTapTool(),
        SimSwipeTool(),
        SimTypeTool(),
        SimDescribeTool(),
        SimScreenshotTool(),
        DescribeImageTool(),
        SimBuildRunTool(),
    ]
    /// Turns attachments into part of the user message: files are quoted
    /// (bounded), images are described through the active vision-capable
    /// provider and their descriptions attached.
    /// Loads the persisted record for a session, but only when it still binds
    /// to the given workspace — a stale session must never be resumed.
    private static func persistedSeed(sessionID: UUID?, workspacePath: String) -> SessionRecord? {
        guard let sessionID else { return nil }
        guard let record = SessionStore.shared.load(id: sessionID),
              record.workspacePath == workspacePath
        else { return nil }
        return record
    }
    private static func expand(attachments: [ComposerAttachment], message: String) -> String {
        guard !attachments.isEmpty else { return message }
        var blocks: [String] = []
        for attachment in attachments {
            if attachment.isImage {
                if let description = Self.describeImage(attachment) {
                    blocks.append("Image \(attachment.name): \(description)")
                } else {
                    blocks.append("Image attached: \(attachment.name) (\(attachment.url.path)) — no vision provider configured to describe it.")
                }
            } else if let data = try? Data(contentsOf: attachment.url),
                      data.count < 16_384 {
                let text = String(decoding: data, as: UTF8.self)
                blocks.append("Attachment \(attachment.name):\n```\n\(text)\n```")
            } else {
                blocks.append("Attachment: \(attachment.name) (\(attachment.url.path)) — too large to inline; use read_file to inspect it.")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n\n" + message
    }

    /// Compact human-readable attachment note for the visible transcript
    /// (the model gets the expanded context; the bubble stays clean).
    private static func attachmentSummary(_ attachments: [ComposerAttachment]) -> String {
        if attachments.count == 1, let only = attachments.first {
            return "1 attachment · \(only.name)"
        }
        return "\(attachments.count) attachments"
    }

    private static func describeImage(_ attachment: ComposerAttachment) -> String? {
        // Synchronous bridge: the vision call is async; fetch it before
        // send() builds the message. Detached so the main actor (blocked on
        // the semaphore below) is never needed to finish the call.
        let semaphore = DispatchSemaphore(value: 0)
        let box = SendableBox<String?>(nil)
        Task.detached {
            do {
                box.value = try await VisionProvider.describe(
                    imageAt: attachment.url,
                    prompt: "Describe this image concisely for a coding agent.")
            } catch {
                box.value = nil
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        return box.value
    }

}

/// A tiny thread-safe box for bridging async results into sync code.
private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}