import Foundation
import SwiftUI

/// Bridges the AgentLoop actor to SwiftUI: consumes the event stream and
/// publishes transcript state. The UI talks only to this controller.
@MainActor
final class AgentSessionController: ObservableObject {

    private enum CodexApprovalKind {
        case commandOrFile
        case permissions(LFJSONValue)
    }

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
    /// True while the model is inside a reasoning block (`<think>…</think>`
    /// or a repetition filler loop) — the transcript shows a proper
    /// "Reasoning…" indicator instead of raw filler text.
    @Published private(set) var isReasoningVisible = false
    /// The reasoning channel currently being generated. It stays separate
    /// from `streamingText` so an answer can stream while the model's visible
    /// work remains available above it.
    @Published private(set) var liveReasoningText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var pendingApproval: ApprovalRequest?
    @Published private(set) var pendingQuestion: String?
    private var pendingQuestionID: UUID?
    @Published private(set) var pendingPlan: String?
    private var pendingPlanID: UUID?
    @Published private(set) var currentPhase: AgentPhase = .idle
    @Published private(set) var finishReason: AgentFinish?
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var gitOutput: String?
    /// True when the open folder has project MCP/hooks the user has not trusted.
    @Published private(set) var workspaceTrustNeeded = false
    /// Selected OpenCode-compatible primary agent. Build is the native
    /// default; Plan is also available from the composer without changing
    /// the rest of the session surface.
    @Published var selectedOpenCodeAgentName: String? = "build"
    private(set) var activeSessionID: UUID?

    private var loop: AgentLoop?
    /// Retained separately from the agent loop so a stop or workspace switch
    /// can cancel the short preparation window before the loop is created.
    private var startTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Live MCP servers for the current run; disconnected when it ends.
    private let mcpRegistry = MCPRegistry()
    /// Live approval overrides for the current run ("Always approve" taps).
    private(set) var approvalOverrides: ApprovalOverrides?
    /// Identifies the current run; events from a cancelled older run are
    /// rejected so they can never mutate a newer run's UI state.
    private var runID = UUID()
    /// Token deltas accumulate here and publish in ~30 ms batches: at local
    /// model speeds per-token publishing causes quadratic string copying and
    /// re-layout for no visible gain.
    private var pendingTokenBuffer = ""
    private var tokenFlushTask: Task<Void, Never>?
    /// Unfiltered stream accumulator — the source for display filtering
    /// (think-block removal happens on the accumulated text, not deltas).
    private var rawStreamingText = ""
    /// Exact-answer smoke prompts are rendered only from the agent's final
    /// message, so a local finetune's conversational filler never flashes in
    /// the transcript while it is generating.
    private var exactAnswerOverride: String?

    // Account-backed OpenAI runs are hosted by Codex app-server rather than
    // AgentLoop. Keeping this state beside the existing loop lets the same
    // transcript, approval card, reasoning surface, and Stop button work for
    // both backends without ever running two tool harnesses for one turn.
    private var codexThreadID: String?
    private var codexTurnID: String?
    private var codexApprovalRequestID: Int?
    private var codexApprovalInvocation: ToolInvocation?
    private var codexApprovalKind: CodexApprovalKind?
    private var codexQuestionRequestID: Int?
    private var codexQuestionID: String?
    private var codexItemInvocations: [String: ToolInvocation] = [:]
    private var codexStreamingText = ""
    private var codexReasoningText = ""
    private var codexRecord: SessionRecord?

    /// Supplies the active model ID (AppState owns that truth).
    var activeModelIDHandler: () -> String = { "" }
    /// Supplies the active account-backed Codex model, if the AppState has
    /// selected one in the composer. Account mode is deliberately separate
    /// from BYOK remote endpoints and local MLX models.
    var activeCodexModelIDHandler: () -> String? = { nil }
    /// Called when the user starts a fresh chat — AppState resets session usage.
    var onSessionReset: (() -> Void)?
    /// Supplies the context window compaction should target: the engine's
    /// real launched ctx when known (GGUF fits it to RAM), else the catalog
    /// window. nil → the Configuration default (32 K).
    var contextWindowHandler: () -> Int? = { nil }
    /// Supplies a remote model's declared output ceiling when known. Local
    /// models continue to use the user's configured per-turn budget.
    var maxTokensHandler: () -> Int? = { nil }
    /// AppState owns the workspace-scoped compatibility catalog.
    var openCodeCatalogHandler: () -> OpenCodeCompatibility.Catalog = { .empty }

    let engine: any LLMEngine
    private let codexAccount: CodexAccountStore
    private let settings: SettingsStore
    private let thermal: ThermalMonitor

    init(
        engine: any LLMEngine,
        settings: SettingsStore,
        thermal: ThermalMonitor,
        codexAccount: CodexAccountStore = .shared
    ) {
        self.engine = engine
        self.codexAccount = codexAccount
        self.settings = settings
        self.thermal = thermal
    }

    // MARK: Task lifecycle

    func send(_ message: String, attachments: [ComposerAttachment] = [], seed: SessionRecord? = nil) {
        guard workspaceURL != nil, !isRunning else { return }

        // Reserve the run synchronously. Without this reservation two remote
        // HTTP requests can both pass the guard before the async MCP/model
        // preparation marks the loop as running.
        isRunning = true
        // A stale event task must never outlive the run it belongs to.
        eventTask?.cancel()
        codexTurnID = nil
        codexApprovalRequestID = nil
        codexApprovalInvocation = nil
        codexApprovalKind = nil
        codexQuestionRequestID = nil
        codexQuestionID = nil
        codexItemInvocations.removeAll()
        codexStreamingText = ""
        codexReasoningText = ""
        pendingApproval = nil
        pendingQuestion = nil
        pendingPlan = nil
        pendingPlanID = nil
        finishReason = nil
        exactAnswerOverride = activeCodexModelIDHandler() == nil
            ? PromptBuilder.exactRequestedAnswer(in: message)
            : nil

        startTask = Task { [weak self] in
            guard let self else { return }
            await self.startRun(message: message, attachments: attachments, seed: seed)
            self.startTask = nil
        }
    }

    /// The async half of `send`: connects MCP servers (bounded, best-effort)
    /// and then starts the loop with built-in + MCP tools merged.
    private func startRun(message: String, attachments: [ComposerAttachment], seed: SessionRecord?) async {
        guard let workspace = workspaceURL, isRunning, !Task.isCancelled else {
            isRunning = false
            return
        }
        let workspaceScope = Workspace(root: workspace)

        // Prepared turn: the transcript shows the user's clean message; the
        // MODEL receives bounded attachment context. The two never mix.
        let modelText = await Self.expand(attachments: attachments, message: message)
        let displayText = attachments.isEmpty ? message : message + "  ·  " + Self.attachmentSummary(attachments)
        transcript.append(TranscriptItem(id: UUID(), kind: .user(displayText)))

        // Continuation seed: an explicit seed wins; otherwise the persisted
        // record for the ACTIVE session is resumed so restored and continued
        // sessions keep their history and checkpoints.
        let continuationSeed = seed ?? Self.persistedSeed(sessionID: activeSessionID, workspacePath: workspace.path)

        // Account-backed OpenAI runs use Codex's own agent harness. It owns
        // command execution, file changes, MCP, and sandbox decisions; Beet
        // Code only renders the resulting events and forwards user approvals.
        if let codexModelID = activeCodexModelIDHandler() {
            await startCodexRun(
                modelID: codexModelID,
                workspace: workspace,
                modelText: modelText,
                displayText: displayText,
                seed: continuationSeed)
            return
        }

        // MCP: connect configured servers, collect their tools. Failures are
        // surfaced as notices but never block the run. A constrained local
        // model cannot afford the full tool/schema prefill on every turn, so
        // it gets a compact core tool set and a lean prompt instead.
        let constrainedLocalModel = Self.isConstrainedLocalModel(
            engine: engine,
            modelID: activeModelIDHandler())
        let trusted = WorkspaceTrust.isTrusted(workspace)
        if WorkspaceTrust.needsConsent(workspace) {
            workspaceTrustNeeded = true
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(
                "This project wants to run MCP servers or hooks. Trust the workspace to enable them.")))
        } else {
            workspaceTrustNeeded = false
        }
        let mcpResult = await mcpRegistry.start(
            workspaceRoot: workspace,
            includeOpenCode: trusted && !constrainedLocalModel,
            includeWorkspace: trusted && !constrainedLocalModel)
        guard isRunning, !Task.isCancelled else {
            isRunning = false
            return
        }
        for error in mcpResult.errors {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(error)))
        }
        if !mcpResult.connectedServers.isEmpty {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(
                "MCP servers connected: \(mcpResult.connectedServers.joined(separator: ", ")) (\(mcpResult.tools.count) tools)")))
        }
        let tools = constrainedLocalModel
            ? Self.constrainedLocalTools
            : Self.defaultTools + mcpResult.tools

        if constrainedLocalModel {
            transcript.append(TranscriptItem(id: UUID(), kind: .notice(
                "Memory-safe local mode: using a compact prompt and core coding tools so this model can answer without exhausting RAM.")))
        }

        let autoApproveEdits = settings.autoApproveEdits
        let autoApproveCommands = settings.autoApproveCommands
        let maxTurns = settings.maxTurns
        let configuredMaxTokensPerTurn = min(
            settings.maxTokensPerTurn,
            maxTokensHandler() ?? settings.maxTokensPerTurn)
        let maxTokensPerTurn = constrainedLocalModel
            ? min(configuredMaxTokensPerTurn, 768)
            : configuredMaxTokensPerTurn
        let configuredContextWindow = contextWindowHandler() ?? 32_768
        let contextWindowTokens = constrainedLocalModel
            ? min(configuredContextWindow, 16_384)
            : configuredContextWindow
        // Smaller local models are more reliable with deterministic tool and
        // short-answer behavior. Keep the user's setting for larger/remote
        // models, but cap constrained local turns at a low sampling value.
        let temperature = constrainedLocalModel
            ? min(settings.temperature, 0.25)
            : settings.temperature
        let checkpointingEnabled = settings.checkpointingEnabled
        let showReasoning = settings.showReasoning
        let catalog = openCodeCatalogHandler()
        let projectPolicy = ProjectPolicy.load(workspaceRoot: workspace)
        let preferredAgentName = projectPolicy?.agent ?? selectedOpenCodeAgentName
        let selectedAgent = catalog.agent(named: preferredAgentName)
            ?? catalog.agent(named: "build")
        let planMode = settings.planMode || selectedAgent?.name.caseInsensitiveCompare("plan") == .orderedSame
        let goalMode = settings.agentMode == .goal
        let outputStyle = projectPolicy?.outputStyle ?? settings.outputStyle
        let compatibilityPermissions = catalog.permissions.merged(with: selectedAgent?.permissions ?? .empty)
        // Per-run live overrides: "Always approve" on an approval card flips
        // these, taking effect immediately for THIS running loop.
        let runOverrides = ApprovalOverrides()
        var permissions = PermissionGate(
            autoApproveEdits: autoApproveEdits,
            autoApproveCommands: autoApproveCommands,
            workspace: workspaceScope,
            overrides: runOverrides)
        permissions.openCodePermissions = compatibilityPermissions
        approvalOverrides = runOverrides

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
                contextWindowTokens: contextWindowTokens,
                thermalTokenCeiling: thermal.maxTokens(ceiling: maxTokensPerTurn),
                verifyAfterEdits: settings.verifyAfterEdits,
                showReasoning: showReasoning,
                planMode: planMode,
                goalMode: goalMode,
                memoryMode: constrainedLocalModel ? .off : settings.memoryMode,
                compressionLevel: constrainedLocalModel ? .aggressive : settings.compressionLevel,
                outputStyle: outputStyle,
                agentName: constrainedLocalModel ? nil : selectedAgent?.name,
                agentPrompt: constrainedLocalModel ? nil : selectedAgent?.prompt,
                intelligenceContext: !constrainedLocalModel,
                allowSubagents: !constrainedLocalModel,
                leanPrompt: constrainedLocalModel),
            modelID: activeModelIDHandler(),
            sessionID: sessionID,
            seedRecord: continuationSeed,
            repoIndex: constrainedLocalModel ? nil : RepoIndexer.build(root: workspace, taskHint: modelText),
            memory: constrainedLocalModel || settings.memoryMode == .off
                ? nil
                : AgentMemory(workspacePath: workspace.path),
            taskHint: modelText)
        loop = agentLoop
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

    // MARK: Codex app-server runs

    private func startCodexRun(
        modelID: String,
        workspace: URL,
        modelText: String,
        displayText: String,
        seed: SessionRecord?
    ) async {
        guard codexAccount.isSignedIn else {
            finishCodex(
                .engineError("Sign in with ChatGPT in Settings → Providers before choosing an OpenAI account model."),
                runID: runID)
            return
        }

        let sessionID = seed?.id ?? UUID()
        var record = seed ?? SessionRecord(
            id: sessionID,
            title: String(displayText.prefix(80)),
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: workspace.path,
            modelID: "openai-codex:\(modelID)",
            messages: [],
            checkpoints: [],
            source: .app,
            schemaVersion: SessionRecord.currentSchemaVersion)
        record.workspacePath = workspace.path
        record.modelID = "openai-codex:\(modelID)"
        record.source = .app
        record.messages.append(SessionMessage(
            role: .user,
            content: displayText,
            toolName: nil,
            timestamp: Date()))
        record.updatedAt = Date()
        codexRecord = record
        activeSessionID = record.id
        SessionStore.shared.currentSessionID = record.id
        SessionStore.shared.save(record)

        let threadInput = Self.codexPrompt(seed: seed, current: modelText)
        let stream = await codexAccount.client.events()

        do {
            let threadID: String
            if let savedThreadID = record.codexThreadID {
                threadID = try await codexAccount.client.resumeThread(
                    threadID: savedThreadID,
                    modelID: modelID,
                    workspace: workspace)
            } else {
                threadID = try await codexAccount.client.startThread(
                    modelID: modelID,
                    workspace: workspace)
            }
            guard isRunning, !Task.isCancelled else { return }
            record.codexThreadID = threadID
            codexRecord = record
            SessionStore.shared.save(record)

            let turnID = try await codexAccount.client.startTurn(
                threadID: threadID,
                modelID: modelID,
                workspace: workspace,
                text: threadInput)
            guard isRunning, !Task.isCancelled else {
                try? await codexAccount.client.interrupt(
                    threadID: threadID,
                    turnID: turnID)
                return
            }
            codexThreadID = threadID
            codexTurnID = turnID
            codexStreamingText = ""
            codexReasoningText = ""
            codexLastError = nil
            currentPhase = .working
            let runToken = runID
            eventTask = Task { [weak self] in
                for await message in stream {
                    guard let self else { return }
                    self.handleCodex(message, runID: runToken)
                }
                self?.codexStreamEnded(runID: runToken)
            }
        } catch {
            guard isRunning, !Task.isCancelled else { return }
            finishCodex(
                .engineError(error.localizedDescription),
                runID: runID)
        }
    }

    private var codexLastError: String?

    private func codexStreamEnded(runID token: UUID) {
        guard token == runID, isRunning else { return }
        finishCodex(
            .engineError(codexLastError ?? "Codex app-server ended before the turn completed."),
            runID: token)
    }

    private func handleCodex(_ message: CodexServerMessage, runID token: UUID) {
        guard token == runID, isRunning else { return }
        if message.isServerRequest {
            handleCodexRequest(message)
            return
        }
        guard let method = message.method,
              let params = message.params?.objectValue
        else { return }

        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return }
            codexStreamingText += delta
            pendingTokenBuffer += delta
            scheduleTokenFlush()

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return }
            codexReasoningText += delta
            if settings.showReasoning {
                liveReasoningText = codexReasoningText
                isReasoningVisible = true
            }

        case "item/plan/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return }
            transcript.append(TranscriptItem(id: UUID(), kind: .reasoning(delta)))

        case "item/started":
            if let item = params["item"]?.objectValue {
                handleCodexItem(item, completed: false)
            }
            currentPhase = .working

        case "item/completed":
            if let item = params["item"]?.objectValue {
                handleCodexItem(item, completed: true)
            }

        case "item/commandExecution/outputDelta":
            // The final command item contains aggregatedOutput. Keeping the
            // transcript to one authoritative result avoids duplicated output
            // while still preserving the live assistant stream.
            break

        case "turn/plan/updated":
            if let plan = params["plan"]?.arrayValue {
                let lines = plan.compactMap { entry -> String? in
                    guard let object = entry.objectValue,
                          let step = object["step"]?.stringValue
                    else { return nil }
                    let status = object["status"]?.stringValue ?? "pending"
                    return status.capitalized + ": " + step
                }
                if !lines.isEmpty {
                    transcript.append(TranscriptItem(
                        id: UUID(),
                        kind: .notice("Codex plan\n" + lines.joined(separator: "\n"))))
                }
            }

        case "turn/completed":
            let turn = params["turn"]?.objectValue
            let status = turn?["status"]?.stringValue?.lowercased() ?? "completed"
            let reason: AgentFinish
            switch status {
            case "completed":
                reason = .completed(Self.codexCompletionSummary(codexStreamingText))
            case "interrupted", "cancelled", "canceled":
                reason = .cancelled
            default:
                let detail = turn?["error"]?.objectValue?["message"]?.stringValue
                    ?? codexLastError
                    ?? "Codex turn failed."
                reason = .engineError(detail)
            }
            finishCodex(reason, runID: token)

        case "error":
            codexLastError = params["error"]?.objectValue?["message"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Codex app-server reported an error."

        case "warning":
            if let warning = params["message"]?.stringValue {
                transcript.append(TranscriptItem(id: UUID(), kind: .notice("Codex: " + warning)))
            }

        case "model/rerouted":
            if let toModel = params["toModel"]?.stringValue {
                transcript.append(TranscriptItem(
                    id: UUID(),
                    kind: .notice("Codex routed this turn to " + toModel + ".")))
            }

        default:
            break
        }
    }

    private func handleCodexRequest(_ message: CodexServerMessage) {
        guard let method = message.method,
              let requestID = message.id,
              let params = message.params?.objectValue
        else { return }

        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let itemID = Self.codexID(params["itemId"])
            let invocation = itemID.flatMap { codexItemInvocations[$0] }
                ?? codexInvocation(for: method, params: params)
            codexApprovalRequestID = requestID
            codexApprovalInvocation = invocation
            codexApprovalKind = .commandOrFile
            pendingApproval = ApprovalRequest(
                id: UUID(),
                invocation: invocation,
                preview: method.contains("command") ? .command(invocation.summary) : .none)
            currentPhase = .awaitingApproval
            DiagnosticsCenter.shared.record(
                .approval,
                "Codex approval requested: " + invocation.name,
                detail: invocation.summary,
                level: .warning)

        case "item/permissions/requestApproval":
            let invocation = codexInvocation(for: method, params: params)
            codexApprovalRequestID = requestID
            codexApprovalInvocation = invocation
            codexApprovalKind = .permissions(params["permissions"] ?? .object([:]))
            pendingApproval = ApprovalRequest(
                id: UUID(),
                invocation: invocation,
                preview: .none)
            currentPhase = .awaitingApproval
            DiagnosticsCenter.shared.record(
                .approval,
                "Codex permission request",
                detail: invocation.summary,
                level: .warning)

        case "item/tool/requestUserInput":
            let question = params["questions"]?.arrayValue?.first?.objectValue
            codexQuestionRequestID = requestID
            codexQuestionID = question?["id"]?.stringValue ?? "answer"
            pendingQuestionID = UUID()
            pendingQuestion = question?["question"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Codex needs more information."
            currentPhase = .awaitingQuestion

        case "item/tool/call":
            // Beet Code currently does not register arbitrary dynamic tools
            // with app-server. Declining explicitly is safer than leaving the
            // turn suspended behind an unanswered JSON-RPC request.
            Task { try? await codexAccount.client.declineDynamicTool(requestID: requestID) }

        case "mcpServer/elicitation/request":
            Task { try? await codexAccount.client.declineElicitation(requestID: requestID) }

        default:
            // Unknown future server requests must never make Stop appear
            // broken. Resolve known approval-shaped requests conservatively.
            if method.localizedCaseInsensitiveContains("approval") {
                Task { try? await codexAccount.client.respondToApproval(
                    requestID: requestID,
                    decision: "decline") }
            }
        }
    }

    private func handleCodexItem(_ item: [String: LFJSONValue], completed: Bool) {
        guard let type = item["type"]?.stringValue else { return }
        if type == "agentMessage" {
            if let finalText = item["text"]?.stringValue, !finalText.isEmpty,
               finalText.count >= codexStreamingText.count {
                codexStreamingText = finalText
                streamingText = finalText
            }
            return
        }
        if type == "reasoning" {
            if let summary = item["summary"]?.stringValue, !summary.isEmpty {
                codexReasoningText = summary
                if settings.showReasoning {
                    liveReasoningText = summary
                    isReasoningVisible = true
                }
            }
            if completed, settings.showReasoning, !codexReasoningText.isEmpty {
                appendCodexMessage(role: .reasoning, content: codexReasoningText)
            }
            return
        }
        guard let itemID = Self.codexID(item["id"]),
              let invocation = codexItemInvocations[itemID]
                ?? codexInvocation(for: type, item: item)
        else { return }

        if codexItemInvocations[itemID] == nil {
            codexItemInvocations[itemID] = invocation
            transcript.append(TranscriptItem(id: UUID(), kind: .toolCall(invocation)))
            appendCodexMessage(
                role: .toolCall,
                content: invocation.argumentsJSON,
                toolName: invocation.name)
        }
        guard completed else { return }

        let output = Self.codexItemOutput(item, type: type)
        let status = item["status"]?.stringValue?.lowercased() ?? "completed"
        let failed = ["failed", "declined", "cancelled", "canceled", "error"].contains(status)
        transcript.append(TranscriptItem(
            id: UUID(),
            kind: .toolResult(
                id: invocation.id,
                output: output,
                failed: failed,
                toolName: invocation.name)))
        appendCodexMessage(
            role: .toolResult,
            content: output,
            toolName: invocation.name)
        DiagnosticsCenter.shared.record(
            .tool,
            "Codex " + invocation.name + " " + (failed ? "failed" : "finished"),
            detail: ByteFormatter.bytes(Int64(output.utf8.count)),
            level: failed ? .error : .info)
    }

    private func finishCodex(_ reason: AgentFinish, runID token: UUID) {
        guard token == runID else { return }
        flushTokens()
        if !codexStreamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prose = Self.cleanedAssistantText(codexStreamingText)
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcript.append(TranscriptItem(id: UUID(), kind: .assistant(prose)))
                appendCodexMessage(role: .assistant, content: prose)
            }
        }
        if settings.showReasoning,
           !codexReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !transcript.contains(where: {
               if case .reasoning(let text) = $0.kind { return text == codexReasoningText }
               return false
           }) {
            transcript.append(TranscriptItem(id: UUID(), kind: .reasoning(codexReasoningText)))
            appendCodexMessage(role: .reasoning, content: codexReasoningText)
        }
        codexRecord?.updatedAt = Date()
        if let record = codexRecord { SessionStore.shared.save(record) }
        streamingText = ""
        rawStreamingText = ""
        exactAnswerOverride = nil
        isReasoningVisible = false
        liveReasoningText = ""
        isRunning = false
        finishReason = reason
        currentPhase = .finished
        clearPending()
        eventTask?.cancel()
        eventTask = nil
        codexTurnID = nil
        codexLastError = nil
        switch reason {
        case .completed:
            DiagnosticsCenter.shared.record(.session, "Codex task completed")
        case .cancelled:
            DiagnosticsCenter.shared.record(.session, "Codex task stopped by user", level: .warning)
        case .maxTurnsReached, .declined:
            break
        case .engineError(let message):
            DiagnosticsCenter.shared.record(.engine, "Codex engine error", detail: message, level: .error)
        }
    }

    private func appendCodexMessage(
        role: SessionMessage.Role,
        content: String,
        toolName: String? = nil
    ) {
        guard !content.isEmpty else { return }
        codexRecord?.messages.append(SessionMessage(
            role: role,
            content: content,
            toolName: toolName,
            timestamp: Date()))
    }

    /// One defensive cleanup path for assistant text entering the visible
    /// transcript. The agent loop still receives valid tool wire format so it
    /// can parse and execute calls; only the user-facing/persisted answer is
    /// stripped here.
    private static func cleanedAssistantText(_ text: String) -> String {
        ToolParser.strippingCalls(from: PromptBuilder.cleaningGeneratedText(text))
    }

    private func codexInvocation(
        for method: String,
        params: [String: LFJSONValue]
    ) -> ToolInvocation {
        let name = method.contains("command") ? "run_command"
            : method.contains("fileChange") ? "apply_patch"
            : "request_permissions"
        let arguments: LFJSONValue
        if name == "run_command" {
            arguments = .object([
                "command": params["command"] ?? .string("(command not provided)"),
                "cwd": params["cwd"] ?? .string("")
            ])
        } else {
            arguments = .object(params)
        }
        let summary = params["reason"]?.stringValue
            ?? params["command"]?.stringValue
            ?? (name == "apply_patch" ? "Codex proposed file changes" : "Codex requested additional permissions")
        return ToolInvocation(
            call: ParsedToolCall(name: name, arguments: arguments, index: 0),
            summary: summary)
    }

    private func codexInvocation(
        for type: String,
        item: [String: LFJSONValue]
    ) -> ToolInvocation? {
        let name: String
        let arguments: LFJSONValue
        let summary: String
        switch type {
        case "commandExecution":
            name = "run_command"
            let command = item["command"] ?? .string("")
            arguments = .object([
                "command": command,
                "cwd": item["cwd"] ?? .string("")
            ])
            summary = Self.codexDisplay(command)
        case "fileChange":
            name = "apply_patch"
            let changes = item["changes"] ?? .array([])
            arguments = .object(["changes": changes])
            let paths = changes.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue } ?? []
            summary = paths.isEmpty ? "Codex proposed file changes" : paths.joined(separator: ", ")
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "mcp"
            let tool = item["tool"]?.stringValue ?? "tool"
            name = "mcp:\(server):\(tool)"
            arguments = item["arguments"] ?? .object([:])
            summary = server + " · " + tool
        case "dynamicToolCall":
            name = "dynamic:\(item["tool"]?.stringValue ?? "tool")"
            arguments = item["arguments"] ?? .object([:])
            summary = name
        case "webSearch":
            name = "web_search"
            arguments = .object(["query": item["query"] ?? .string("")])
            summary = item["query"]?.stringValue ?? "Web search"
        case "imageView":
            name = "view_image"
            arguments = .object(["path": item["path"] ?? .string("")])
            summary = item["path"]?.stringValue ?? "View image"
        default:
            return nil
        }
        return ToolInvocation(
            call: ParsedToolCall(name: name, arguments: arguments, index: 0),
            summary: summary)
    }

    private static func codexItemOutput(_ item: [String: LFJSONValue], type: String) -> String {
        if let error = item["error"]?.objectValue?["message"]?.stringValue { return "error: " + error }
        switch type {
        case "commandExecution":
            return item["aggregatedOutput"]?.stringValue
                ?? item["status"]?.stringValue
                ?? "Command finished."
        case "fileChange":
            let paths = item["changes"]?.arrayValue?.compactMap {
                $0.objectValue?["path"]?.stringValue
            } ?? []
            return paths.isEmpty ? "File changes finished." : "Changed: " + paths.joined(separator: ", ")
        case "mcpToolCall":
            return item["result"]?.stringValue
                ?? item["result"]?.encoded(prettyPrinted: true)
                ?? "MCP tool finished."
        default:
            return item["contentItems"]?.encoded(prettyPrinted: true)
                ?? item["status"]?.stringValue
                ?? "Tool finished."
        }
    }

    private static func codexID(_ value: LFJSONValue?) -> String? {
        value?.stringValue ?? value?.intValue.map(String.init)
    }

    private static func codexDisplay(_ value: LFJSONValue) -> String {
        if let text = value.stringValue { return text }
        if let parts = value.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return value.encoded()
    }

    private static func codexPrompt(seed: SessionRecord?, current: String) -> String {
        guard let seed, seed.codexThreadID == nil, !seed.messages.isEmpty else { return current }
        let history = seed.messages.suffix(12).compactMap { message -> String? in
            guard message.role == .user || message.role == .assistant else { return nil }
            let content = String(message.content.prefix(2_000))
            return (message.role == .user ? "User" : "Assistant") + ": " + content
        }
        guard !history.isEmpty else { return current }
        return "Previous Beet Code conversation context:\n\(history.joined(separator: "\n\n"))\n\nCurrent request:\n\(current)"
    }

    private static func codexCompletionSummary(_ text: String) -> String {
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Codex turn completed." : String(summary.prefix(240))
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if loop == nil, let threadID = codexThreadID, let turnID = codexTurnID {
            let token = runID
            let client = codexAccount.client
            Task {
                try? await client.interrupt(threadID: threadID, turnID: turnID)
            }
            finishCodex(.cancelled, runID: token)
            return
        }
        guard let loop else {
            guard isRunning else { return }
            isRunning = false
            finishReason = .cancelled
            currentPhase = .finished
            clearPending()
            return
        }
        Task { await loop.cancel() }
    }

    /// Starts the next turn of a persisted Beetcode session from the remote
    /// browser surface. The session is restored first, so the agent loop gets
    /// the same transcript, workspace binding, model choice, and checkpoints
    /// as a local continuation.
    @discardableResult
    func continuePersistedSession(id: UUID, message: String) -> Bool {
        guard !isRunning,
              let record = SessionStore.shared.load(id: id),
              record.source == .app,
              SessionStore.shared.validateWorkspaceBinding(record),
              restore(record) else { return false }
        send(message)
        return true
    }

    /// Switches the controller to a different workspace as ONE transaction:
    /// the active run fully stops first, interactive state is cleared, and the
    /// workspace's most recent session (if any) is restored. Undo and git
    /// controls then target the new project — never a stale checkpoint from
    /// the old one.
    func switchWorkspace(to url: URL, sessionID: UUID? = nil) async {
        await stopAndWait()
        workspaceURL = url
        activeSessionID = nil
        gitOutput = nil
        transcript = []
        finishReason = nil
        streamingText = ""
        rawStreamingText = ""
        exactAnswerOverride = nil
        isReasoningVisible = false
        liveReasoningText = ""
        workspaceTrustNeeded = WorkspaceTrust.needsConsent(url)
        // Background intelligence index: incremental when a baseline exists,
        // full on first open. Silent on failure — the agent loop degrades to
        // no injected context, never to a blocked session.
        Task.detached(priority: .utility) {
            _ = try? await WorkspaceIntelligence(workspaceRoot: url).update()
        }
        if let sessionID,
           let record = SessionStore.shared.load(id: sessionID),
           record.workspacePath == url.path {
            _ = restore(record)
        } else if let latest = SessionStore.shared.loadAll()
            .first(where: { $0.workspacePath == url.path }) {
            _ = restore(latest)
        }
    }

    func trustCurrentWorkspace() {
        guard let url = workspaceURL else { return }
        WorkspaceTrust.trust(url)
        workspaceTrustNeeded = false
        notice("Trusted this workspace. Project MCP servers and hooks will run on the next message.")
    }

    /// Starts a fresh chat in the current workspace: the transcript clears
    /// and the next send begins a brand-new session record — no continuation
    /// seed, and the app no longer points at the old session on relaunch.
    func newSession() {
        startTask?.cancel()
        startTask = nil
        let oldLoop = loop
        loop = nil
        eventTask?.cancel()
        eventTask = nil
        if let oldLoop {
            Task { await oldLoop.cancel() }
        }
        codexThreadID = nil
        codexTurnID = nil
        codexRecord = nil
        codexItemInvocations.removeAll()
        runID = UUID()
        isRunning = false
        clearPending()
        finishReason = nil
        dropTokenBuffer()
        streamingText = ""
        rawStreamingText = ""
        exactAnswerOverride = nil
        isReasoningVisible = false
        liveReasoningText = ""
        activeSessionID = nil
        gitOutput = nil
        transcript = []
        SessionStore.shared.currentSessionID = nil
        onSessionReset?()
    }

    /// Stops the active run and WAITS for the loop to reach its terminal
    /// state before returning. Engine transitions (load/unload/source swap)
    /// must await this so a generation can never outlive its model.
    func stopAndWait() async {
        startTask?.cancel()
        startTask = nil
        if loop == nil, codexTurnID != nil {
            let threadID = codexThreadID
            let turnID = codexTurnID
            let client = codexAccount.client
            if let threadID, let turnID {
                try? await client.interrupt(threadID: threadID, turnID: turnID)
            }
            cancelCodexState()
            return
        }
        guard let loop else {
            runID = UUID()
        isRunning = false
        currentPhase = .finished
        clearPending()
        exactAnswerOverride = nil
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
        rawStreamingText = ""
        exactAnswerOverride = nil
        isReasoningVisible = false
        liveReasoningText = ""
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
        rawStreamingText = ""
        exactAnswerOverride = nil
        isReasoningVisible = false
        liveReasoningText = ""
        clearPending()
    }

    private func clearPending() {
        pendingApproval = nil
        pendingQuestion = nil
        pendingQuestionID = nil
        pendingPlan = nil
        pendingPlanID = nil
        codexApprovalRequestID = nil
        codexApprovalInvocation = nil
        codexApprovalKind = nil
        codexQuestionRequestID = nil
        codexQuestionID = nil
    }

    private func cancelCodexState() {
        runID = UUID()
        eventTask?.cancel()
        eventTask = nil
        isRunning = false
        finishReason = .cancelled
        currentPhase = .finished
        codexTurnID = nil
        codexLastError = nil
        clearPending()
        dropTokenBuffer()
        streamingText = ""
        rawStreamingText = ""
        isReasoningVisible = false
        liveReasoningText = ""
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
        rawStreamingText += pendingTokenBuffer
        pendingTokenBuffer = ""
        if exactAnswerOverride != nil {
            // The final assistant event publishes the exact requested text.
            // Suppress the raw generation path so filler cannot appear first.
            streamingText = ""
            isReasoningVisible = false
            liveReasoningText = ""
            return
        }
        // Display filtering: hide raw `…` blocks and repetition
        // filler ("thinking thinking thinking…") — show a proper
        // Reasoning indicator instead of the model's raw noise.
        let (visible, reasoning) = StreamDisplayFilter.display(raw: rawStreamingText)
        streamingText = visible
        isReasoningVisible = reasoning
        liveReasoningText = settings.showReasoning
            ? StreamDisplayFilter.reasoningText(raw: rawStreamingText)
            : ""
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
        startTask?.cancel()
        startTask = nil
        let oldLoop = loop
        loop = nil
        eventTask?.cancel()
        eventTask = nil
        if let oldLoop {
            Task { await oldLoop.cancel() }
        }
        codexThreadID = record.codexThreadID
        codexTurnID = nil
        codexRecord = record.modelID.hasPrefix("openai-codex:") ? record : nil
        codexItemInvocations.removeAll()
        runID = UUID()
        isRunning = false
        pendingApproval = nil
        pendingQuestion = nil
        pendingQuestionID = nil
        pendingPlan = nil
        pendingPlanID = nil
        finishReason = nil
        dropTokenBuffer()
        streamingText = ""
        rawStreamingText = ""
        isReasoningVisible = false
        liveReasoningText = ""
        workspaceURL = URL(fileURLWithPath: record.workspacePath)

        var rebuilt: [TranscriptItem] = []
        for message in record.messages {
            switch message.role {
            case .user:
                rebuilt.append(TranscriptItem(id: UUID(), kind: .user(message.content)))
            case .assistant:
                // Sanitize restored history the same way as live events:
                // older sessions stored raw tool-call JSON in assistant text.
                let prose = Self.cleanedAssistantText(message.content)
                if !prose.isEmpty {
                    rebuilt.append(TranscriptItem(id: UUID(), kind: .assistant(prose)))
                }
            case .reasoning:
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rebuilt.append(TranscriptItem(id: UUID(), kind: .reasoning(message.content)))
                }
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

    /// The request identifier is needed by remote clients so a stale approval
    /// or question response cannot resolve a newer interaction accidentally.
    var pendingQuestionRequestID: UUID? { pendingQuestionID }
    var pendingPlanRequestID: UUID? { pendingPlanID }

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

        case .auto:
            settings.agentMode = .auto
            notice("Auto mode ON — direct execution with normal approval gates.")

        case .goal:
            settings.agentMode = .goal
            notice("Goal mode ON — the agent plans first, then works through the goal until completion.")

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
            notice(Self.helpText(home: FileManager.default.homeDirectoryForCurrentUser,
                                 workspace: workspaceURL))

        case .unknown(let raw):
            // Universal compatibility: an unrecognized slash name may be a
            // Claude skill/command, a Codex prompt, or a BeetCode command
            // discovered in the convention directories. Its text expands
            // into the next user message — the same contract those tools
            // give their own files.
            let parts = raw.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let name = parts.first.map { String($0).lowercased() } ?? ""
            let args = parts.count > 1 ? String(parts[1]) : ""
            let home = FileManager.default.homeDirectoryForCurrentUser
            let extraRoots = AppPreferencesStore.shared.current.externalResourceURLs
            guard let command = ExternalCommands.command(
                named: name, home: home, workspace: workspaceURL,
                additionalRoots: extraRoots) else {
                notice("Unknown command '\(name)'. Try /help.")
                return true
            }
            guard workspaceURL != nil else {
                notice("/\(name) needs an open workspace folder.")
                return true
            }
            guard !isRunning else {
                notice("Wait for the current run to finish before invoking /\(name).")
                return true
            }
            notice("Running \(command.origin.rawValue) \(command.kind.label) '/\(name)'.")
            let rendered = command.render(arguments: args)
            let message: String
            if command.origin == .openCode || args.isEmpty {
                message = rendered.isEmpty ? args : rendered
            } else {
                message = rendered + "\n\nUser input:\n" + args
            }
            send(message, attachments: [])
        }
        return true
    }

    /// /help output: the built-in catalog plus any external commands
    /// discovered in the workspace and home convention directories.
    static func helpText(home: URL, workspace: URL?) -> String {
        let external = ExternalCommands.discover(
            home: home,
            workspace: workspace,
            additionalRoots: AppPreferencesStore.shared.current.externalResourceURLs)
        guard !external.isEmpty else { return SlashCommand.helpText }
        let lines = external.map { "  /\($0.name)  (\($0.origin.rawValue) \($0.kind.label))" }
        return SlashCommand.helpText
            + "\n\nExternal commands (Claude / Codex / BeetCode convention dirs):\n"
            + lines.joined(separator: "\n")
    }

    /// Compresses the active session's history immediately and persists the
    /// result — the next send continues with the compacted record. This is
    /// exposed for the composer preflight meter; slash commands use the same
    /// path so both entry points have identical behavior.
    func compactNow() {
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

    private func compactSessionNow() {
        compactNow()
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

    @discardableResult
    func approvePlan(requestID: UUID? = nil) -> Bool {
        guard pendingPlan != nil,
              requestID == nil || requestID == pendingPlanID else { return false }
        pendingPlan = nil
        pendingPlanID = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .notice("Plan approved — executing.")))
        DiagnosticsCenter.shared.record(.approval, "Plan approved — executing")
        if let loop {
            Task { await loop.resolvePlan(approved: true) }
        }
        return true
    }

    @discardableResult
    func revisePlan(_ feedback: String, requestID: UUID? = nil) -> Bool {
        guard pendingPlan != nil,
              requestID == nil || requestID == pendingPlanID else { return false }
        pendingPlan = nil
        pendingPlanID = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .user(feedback)))
        DiagnosticsCenter.shared.record(.approval, "Plan sent back for revision")
        if let loop {
            Task { await loop.resolvePlanRevision(feedback: feedback) }
        }
        return true
    }

    // MARK: Interactive responses

    func approve(_ approved: Bool) {
        approve(approved, always: false)
    }

    /// Decides a pending approval. `always: true` additionally widens
    /// approval for the rest of this run AND future runs (persisted):
    /// - a write tool (edit/write) enables auto-approve file edits
    /// - run_command enables auto-approve for policy-safe commands
    /// Reads never ask, so they never reach this path. The widening keeps
    /// every existing safety rail: command approval remains gated by the
    /// allowlist policy in PermissionGate.
    func approve(_ approved: Bool, always: Bool) {
        guard let request = pendingApproval else { return }
        let codexRequestID = codexApprovalRequestID
        let codexKind = codexApprovalKind
        pendingApproval = nil
        if approved {
            transcript.append(
                TranscriptItem(id: UUID(), kind: .notice("Approved: \(request.invocation.name)")))
            DiagnosticsCenter.shared.record(.approval, "\(request.invocation.name) approved\(always ? " (always)" : "")")
            if always {
                applyAlwaysApproval(for: request)
            }
        } else {
            transcript.append(
                TranscriptItem(id: UUID(), kind: .notice("Declined: \(request.invocation.name)")))
            DiagnosticsCenter.shared.record(.approval, "\(request.invocation.name) declined", level: .warning)
        }
        if let codexRequestID {
            let client = codexAccount.client
            switch codexKind {
            case .permissions(let requested):
                let granted = approved ? requested : .object([:])
                Task {
                    try? await client.respondToPermissions(
                        requestID: codexRequestID,
                        permissions: granted,
                        scope: approved && always ? "session" : "turn")
                }
            case .commandOrFile, .none:
                Task {
                    try? await client.respondToApproval(
                        requestID: codexRequestID,
                        decision: approved ? (always ? "acceptForSession" : "accept") : "decline")
                }
            }
            codexApprovalRequestID = nil
            codexApprovalInvocation = nil
            codexApprovalKind = nil
            currentPhase = .working
            return
        }
        if let loop {
            Task { await loop.resolve(requestID: request.id, approved: approved) }
        }
    }

    private func applyAlwaysApproval(for request: ApprovalRequest) {
        let isCommand = request.invocation.name == "run_command"
            || request.invocation.name == "build_diagnostics"
        if isCommand {
            approvalOverrides?.allowCommands()
            SettingsStore.shared.autoApproveCommands = true
            transcript.append(TranscriptItem(
                id: UUID(),
                kind: .notice("Always approve enabled for safe commands (this run + future runs)")))
        } else {
            approvalOverrides?.allowEdits()
            SettingsStore.shared.autoApproveEdits = true
            transcript.append(TranscriptItem(
                id: UUID(),
                kind: .notice("Always approve enabled for file edits (this run + future runs)")))
        }
    }

    func answerQuestion(_ text: String) {
        guard let requestID = pendingQuestionID, pendingQuestion != nil, !text.isEmpty else { return }
        let codexRequestID = codexQuestionRequestID
        let codexID = codexQuestionID ?? "answer"
        pendingQuestion = nil
        pendingQuestionID = nil
        transcript.append(TranscriptItem(id: UUID(), kind: .user(text)))
        if let codexRequestID {
            let client = codexAccount.client
            Task {
                try? await client.respondToUserInput(
                    requestID: codexRequestID,
                    questionID: codexID,
                    answer: text)
            }
            self.codexQuestionRequestID = nil
            self.codexQuestionID = nil
            currentPhase = .working
            return
        }
        if let loop {
            Task { await loop.answerQuestion(requestID: requestID, text: text) }
        }
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, runID token: UUID) {
        guard token == runID else { return }
        // Diagnostics: every event is also a breadcrumb (metadata only —
        // never message contents). See docs/DIAGNOSTICS-SPEC.md.
        let diagnostics = DiagnosticsCenter.shared
        switch event {
        case .taskStarted:
            flushTokens()
            streamingText = ""
            rawStreamingText = ""
            isReasoningVisible = false
            liveReasoningText = ""
            diagnostics.record(.session, "Task started")

        case .tokenDelta(let chunk):
            pendingTokenBuffer += chunk
            scheduleTokenFlush()

        case .assistantMessage(let text):
            flushTokens()
            streamingText = ""
            rawStreamingText = ""
            isReasoningVisible = false
            liveReasoningText = ""
            // Wire format never reaches the transcript: strip tool-call
            // syntax, and drop the bubble entirely if nothing else remains.
            let prose = Self.cleanedAssistantText(text)
            if !prose.isEmpty {
                transcript.append(TranscriptItem(id: UUID(), kind: .assistant(prose)))
            }

        case .toolCallStarted(let invocation):
            flushTokens()
            streamingText = ""
            rawStreamingText = ""
            isReasoningVisible = false
            liveReasoningText = ""
            transcript.append(TranscriptItem(id: UUID(), kind: .toolCall(invocation)))
            diagnostics.record(.tool, "\(invocation.name) started", detail: invocation.summary)

        case .awaitingApproval(let request):
            pendingApproval = request
            diagnostics.record(.approval, "Approval requested: \(request.invocation.name)",
                               detail: request.invocation.summary, level: .warning)

        case .toolCallFinished(let invocation, let output, let failed):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .toolResult(id: invocation.id, output: output, failed: failed, toolName: invocation.name)))
            diagnostics.record(
                .tool, "\(invocation.name) \(failed ? "failed" : "finished")",
                detail: ByteFormatter.bytes(Int64(output.utf8.count)),
                level: failed ? .error : .info)

        case .askUser(let requestID, let question):
            pendingQuestionID = requestID
            pendingQuestion = question
            diagnostics.record(.approval, "The agent asked a question",
                               detail: String(question.prefix(120)))

        case .checkpointCreated(let checkpoint):
            transcript.append(
                TranscriptItem(id: UUID(), kind: .checkpoint(checkpoint)))
            diagnostics.record(.tool, "Checkpoint saved", detail: checkpoint.summary)

        case .checkpointFailed(let reason):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Checkpoint failed — the action was NOT executed: \(reason)")))
            diagnostics.record(.tool, "Checkpoint failed — action not executed",
                               detail: reason, level: .error)

        case .protocolError(let message):
            transcript.append(
                TranscriptItem(
                    id: UUID(),
                    kind: .notice("Tool protocol error: \(message)")))
            diagnostics.record(.tool, "Protocol error", detail: message, level: .warning)

        case .reasoning(let text):
            liveReasoningText = text
            if let lastIndex = transcript.indices.last,
               case .reasoning(let previous) = transcript[lastIndex].kind {
                transcript[lastIndex].kind = .reasoning(previous + "\n\n" + text)
            } else {
                transcript.append(
                    TranscriptItem(id: UUID(), kind: .reasoning(text)))
            }

        case .planProposed(let plan):
            pendingPlan = plan
            pendingPlanID = UUID()
            diagnostics.record(.approval, "Plan proposed — waiting for approval")

        case .phaseChanged(let phase):
            currentPhase = phase

        case .finished(let reason):
            flushTokens()
            streamingText = ""
            rawStreamingText = ""
            isReasoningVisible = false
            liveReasoningText = ""
            isRunning = false
            finishReason = reason
            clearPending()
            loop = nil
            eventTask = nil
            switch reason {
            case .completed:
                diagnostics.record(.session, "Task completed")
            case .cancelled:
                diagnostics.record(.session, "Task stopped by user", level: .warning)
            case .declined(let detail):
                diagnostics.record(.session, "Task declined", detail: detail, level: .warning)
            case .maxTurnsReached(let turns):
                diagnostics.record(.session, "Turn limit reached (\(turns))", level: .warning)
            case .engineError(let message):
                diagnostics.record(.engine, "Engine error", detail: message, level: .error)
            }
        }
    }

    // MARK: Tool registry

    static let defaultTools: [any AgentTool] = [
        ReadFileTool(),
        WriteFileTool(),
        MoveFileTool(),
        ListDirectoryTool(),
        SearchTool(),
        FindFilesTool(),
        FindFilesTool(name: "glob"),
        WebFetchTool(),
        BackgroundProcessTool(),
        BackgroundStatusTool(),
        ApplyPatchTool(),
        RunCommandTool(),
        BuildDiagnosticsTool(),
        CreateMacAppTool(),
        CreateIOSAppTool(),
        MacBuildRunTool(),
        AppleShipTool(),
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
        // In-app browser: extraction is auto-approved; navigation/click/
        // type/eval go through the approval card like every other mutation.
        BrowserTools.ReadTool(),
        BrowserTools.ScreenshotTool(),
        BrowserTools.NavigateTool(),
        BrowserTools.ClickTool(),
        BrowserTools.TypeTool(),
        BrowserTools.EvalTool(),
        // Computer use: drive ANY Mac app. Observation (status/ui tree/
        // screenshot) is auto-approved; input actions go through the
        // approval card like every other mutation.
        ComputerStatusTool(),
        ComputerUITreeTool(),
        ComputerScreenshotTool(),
        ComputerClickTool(),
        ComputerTypeTool(),
        ComputerKeyTool(),
        ComputerScrollTool(),
    ]

    /// The compact registry used when a local model is close to the machine's
    /// RAM ceiling. These tools preserve the core coding workflow while
    /// avoiding browser, simulator, computer-use, and app-scaffolding schemas
    /// in every model prefill.
    static let constrainedLocalTools: [any AgentTool] = [
        ReadFileTool(),
        WriteFileTool(),
        ListDirectoryTool(),
        SearchTool(),
        FindFilesTool(),
        ApplyPatchTool(),
        RunCommandTool(),
    ]

    private static func isConstrainedLocalModel(
        engine: any LLMEngine,
        modelID: String
    ) -> Bool {
        guard let router = engine as? EngineRouter,
            router.source == .localMLX,
            let model = ModelCatalog.model(id: modelID),
            model.role == .chat
        else { return false }

        // On a 16 GB Apple Silicon Mac, even a smaller local model can spend
        // most of a turn prefilling thousands of tool-schema tokens. Keep the
        // full agent surface on machines with more headroom and use the core
        // coding surface below 24 GB of physical RAM.
        let constrainedMachine = MemoryAdvisor.physicalMemory < 24 * 1024 * 1024 * 1024
        return constrainedMachine
    }
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
    /// Async: local VLM first load can take seconds (weights page-in), and a
    /// BYOK describe is a network call — a synchronous bridge with a fixed
    /// timeout here used to misreport slow-but-working vision as missing.
    private static func expand(attachments: [ComposerAttachment], message: String) async -> String {
        guard !attachments.isEmpty else { return message }
        var blocks: [String] = []
        for attachment in attachments {
            if attachment.isImage {
                if let description = try? await VisionProvider.describe(
                    imageAt: attachment.url,
                    prompt: "Describe this image concisely for a coding agent.") {
                    blocks.append("Image \(attachment.name): \(description)")
                } else {
                    blocks.append("Image attached: \(attachment.name) (\(attachment.url.path)) — no vision model available to describe it (download SmolVLM2 in the Model Manager or add a vision API key in Settings).")
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

}
