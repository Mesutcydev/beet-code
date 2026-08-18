import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared

    init(controller: AgentSessionController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .background(surfaceBackground)
        // Intent palette expands inline above the input; Esc is reserved for
        // stopping the agent, never for collapsing the palette.
    }

    // MARK: Transcript

    @State private var isPinnedToBottom = true

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if controller.transcript.isEmpty && controller.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(controller.transcript) { item in
                        TranscriptRow(item: item)
                            .id(item.id)
                    }
                    if !controller.streamingText.isEmpty {
                        StreamingCard(text: controller.streamingText)
                    }
                    if let approval = controller.pendingApproval {
                        ApprovalCard(request: approval) { approved in
                            controller.approve(approved)
                        }
                    }
                    if let question = controller.pendingQuestion {
                        QuestionCard(question: question) { answer in
                            controller.answerQuestion(answer)
                        }
                    }
                    if let plan = controller.pendingPlan {
                        PlanCard(plan: plan) { feedback in
                            if let feedback {
                                controller.revisePlan(feedback)
                            } else {
                                controller.approvePlan()
                            }
                        }
                    }
                    if let finish = controller.finishReason {
                        FinishBanner(reason: finish)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Pinned means the viewport bottom is within ~40 pt of the
                // content bottom — the user is following the output.
                let visibleMax = geometry.contentOffset.y + geometry.containerSize.height
                let contentHeight = geometry.contentSize.height
                return contentHeight - visibleMax < 40
            } action: { _, pinned in
                isPinnedToBottom = pinned
            }
            .onChange(of: controller.transcript.count) { _, _ in
                guard isPinnedToBottom else { return }
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: controller.streamingText) { _, _ in
                guard isPinnedToBottom else { return }
                proxy.scrollTo("bottom")
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom && controller.isRunning {
                    Button {
                        isPinnedToBottom = true
                        withAnimation { proxy.scrollTo("bottom") }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            // Distinct glyph + tint per engine state: idle/setup reads as
            // "get started" (hammer, accent); a failed load reads as a
            // warning (triangle, danger) so the two are never confused.
            if case .failed = appState.enginePhase {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.danger.opacity(0.9))
                    .shadow(color: Theme.danger.opacity(0.30), radius: 18, y: 4)
            } else {
                Image(systemName: "hammer.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accentGradient)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 4)
            }
            Text(emptyTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Open a project folder, pick a downloaded model, and describe a coding task. Reads run automatically; every edit and command shows up here for approval.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var emptyTitle: String {
        switch appState.enginePhase {
        case .idle: "No model loaded — open the Model Manager (⌘M)"
        case .loading: "Loading model…"
        case .ready: "Ready — describe a task"
        case .failed: "Model failed to load — check the Model Manager"
        }
    }

    // MARK: Input

    private var inputBar: some View {
        let flow = settings.composerFlow
        let phase: ComposerPhase = controller.pendingApproval != nil
            ? .awaitingApproval
            : (controller.isRunning ? .streaming : (isFocused ? .focused : .idle))

        return VStack(alignment: .leading, spacing: 6) {
            // Task phase indicator.
            if controller.currentPhase != .idle, controller.currentPhase != .finished {
                HStack(spacing: 6) {
                    Image(systemName: phaseIcon(controller.currentPhase))
                        .foregroundStyle(.secondary)
                    Text(phaseLabel(controller.currentPhase))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Attachment chips (Cursor-style context row).
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }

            if lattice.isExpanded {
                IntentPalette(
                    model: lattice,
                    estimatedTokens: lattice.estimatedTokens(draft: draft),
                    contextWindow: appState.activeModel?.contextWindow
                )
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lfGlass(radius: Radius.lg)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Queued messages (sent in order as runs finish).
            if !queue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("QUEUED · \(queue.count)")
                        .font(.system(size: 8, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    ForEach(queue) { q in
                        HStack(spacing: 6) {
                            Image(systemName: "text.queue").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(q.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            Button { queue.removeAll { $0.id == q.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.surfaceInset, in: Capsule())
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Attachment button (paperclip).
                Button {
                    attachFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Attach files or images (⌘V pastes a screenshot)")
                .disabled(controller.isRunning)

                // Auto-expanding textarea: 1 → 8 lines, then scrolls.
                TextField(
                    composerPlaceholder,
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onSubmit(sendMessage)
                .disabled(!canCompose)
                .focused($inputFocused)
                .padding(10)
                .modifier(ComposerBorder(flow: flow, phase: phase, animated: settings.composerBorderAnimation))

                if controller.isRunning {
                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop the agent (Esc)")
                    .keyboardShortcut(.cancelAction)
                }
                // Send now, or queue while the agent is running.
                Button {
                    sendMessage()
                } label: {
                    let ready = !draft.isEmpty && canCompose
                    Image(systemName: controller.isRunning ? "text.append" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ready ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.textTertiary))
                        .frame(width: 30, height: 30)
                        .background(ready ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceInset),
                                    in: Circle())
                        .overlay(Circle().strokeBorder(Theme.hairline.opacity(ready ? 0 : 1), lineWidth: 1))
                        .shadow(color: ready ? Theme.accent.opacity(0.4) : .clear, radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty || !canCompose)
                .help(controller.isRunning ? "Queue message (sent when the run finishes)" : "Send")
            }

            // Accessory row: model, intent, plan, reasoning.
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.isRemoteActive ? Theme.info : Theme.success)
                        .frame(width: 6, height: 6)
                    Text(modelLabel).lineLimit(1)
                    Text(appState.isRemoteActive ? "REMOTE" : "LOCAL")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(appState.isRemoteActive ? Theme.info : Theme.success)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

                Spacer()

                // Intent palette: roles + focus chips. Esc is reserved for Stop.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        lattice.isExpanded.toggle()
                    }
                } label: {
                    if lattice.selectionCount > 0 {
                        Label("Intent · \(lattice.selectionCount)", systemImage: "sparkles")
                    } else {
                        Label("Intent", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .accessoryControl()
                .tint(lattice.isExpanded ? Color.accentColor : nil)
                .help("Add roles and focus sources to this turn")
                .disabled(controller.isRunning)

                Toggle(isOn: $settings.planMode) {
                    Label("Plan", systemImage: "list.bullet.clipboard")
                }
                .toggleStyle(.button)
                .accessoryControl()
                .help("Plan mode: the agent proposes a plan before any tool runs")

                Toggle(isOn: $settings.showReasoning) {
                    Label("Reasoning", systemImage: "brain.head.profile")
                }
                .toggleStyle(.button)
                .accessoryControl()
                .help("Show the model's chain-of-thought")
            }
            .font(.caption)
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onChange(of: controller.isRunning) { _, running in
            if !running { drainQueue() }
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { providers in
            handlePaste(providers)
        }
    }

    /// Deepest app surface behind the transcript.
    private var surfaceBackground: Color { Theme.bg }

    private var isFocused: Bool { inputFocused }
    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @FocusState private var inputFocused: Bool
    // Intent palette: collapsed by default so the single-line case is unchanged.
    @StateObject private var lattice = LatticeModel()

    // Messages typed while the agent is running are queued and sent in order
    // as each run finishes.
    private struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var queue: [QueuedMessage] = []


    private var inputDisabled: Bool {
        controller.workspaceURL == nil
            || !isEngineReady
            || controller.isRunning
            || controller.pendingApproval != nil
            || controller.pendingQuestion != nil
    }

    private var isEngineReady: Bool {
        if case .ready = appState.enginePhase { return true }
        return false
    }

    private var composerPlaceholder: String {
        if controller.workspaceURL == nil { return "Open a workspace to begin…" }
        if !isEngineReady { return "Load a model to begin…" }
        return "Describe a coding task…"
    }

    /// Composing is allowed whenever a workspace + engine are ready; a running
    /// agent no longer blocks typing (messages queue instead).
    private var canCompose: Bool {
        controller.workspaceURL != nil
            && isEngineReady
            && controller.pendingApproval == nil
            && controller.pendingQuestion == nil
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Slash commands execute locally — never sent to the model.
        if controller.handleSlash(text) {
            draft = ""
            return
        }
        // While the agent runs, queue instead of interrupting.
        if controller.isRunning {
            queue.append(QueuedMessage(text: text))
            draft = ""
            return
        }
        let outgoing = attachments
        let preamble = lattice.contextPreamble(
            workspace: controller.workspaceURL,
            attachments: outgoing,
            draft: text,
            contextWindow: appState.activeModel?.contextWindow)
        let message = preamble.map { $0 + "\n\n" + text } ?? text
        draft = ""
        attachments = []
        lattice.clear()
        withAnimation(.easeInOut(duration: 0.18)) {
            lattice.isExpanded = false
        }
        controller.send(message, attachments: outgoing)
    }

    /// Sends the next queued message once a run finishes.
    private func drainQueue() {
        guard !controller.isRunning, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        controller.send(next.text, attachments: [])
    }

    private func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .idle: "Idle"
        case .planning: "Planning…"
        case .awaitingPlanApproval: "Awaiting plan approval"
        case .working: "Working…"
        case .awaitingApproval: "Awaiting approval"
        case .awaitingQuestion: "Awaiting your answer"
        case .verifying: "Verifying…"
        case .finished: "Done"
        }
    }

    private func phaseIcon(_ phase: AgentPhase) -> String {
        switch phase {
        case .planning, .working, .verifying: "circle.dotted"
        case .awaitingPlanApproval, .awaitingApproval, .awaitingQuestion: "hand.raised"
        default: "circle"
        }
    }

    private var modelLabel: String {
        if appState.isRemoteActive,
           let endpoint = appState.engine.activeRemoteEndpoint {
            return "\(endpoint.provider.displayName) · \(endpoint.model)"
        }
        return appState.activeModel?.displayName ?? "local"
    }

    /// Paperclip: pick files and/or images from disk.
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files or images"
        panel.message = "Files are quoted into the message; images are described by the vision provider."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls.prefix(8) {
                attachments.append(ComposerAttachment(url: url))
            }
        }
    }

    /// ⌘V: paste images (screenshots) or file URLs.
    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async {
                            attachments.append(ComposerAttachment(url: url))
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let image = NSImage(data: data) {
                        let dir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("beetcode-paste", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970)).png")
                        if let data = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: data),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: url)
                            DispatchQueue.main.async {
                                attachments.append(ComposerAttachment(url: url, isImage: true))
                            }
                        }
                    }
                }
            }
        }
    }

}
// MARK: - Rows

private struct TranscriptRow: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer()
                Text(text)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1))
                    .frame(maxWidth: 520, alignment: .trailing)
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            AssistantBubble(text: text)
        case .toolCall(let invocation):
            ToolCallRow(invocation: invocation)
        case .toolResult(let id, let output, let failed, let toolName):
            ToolResultRow(callID: id, output: output, failed: failed, toolName: toolName)
        case .reasoning(let text):
            ReasoningCard(text: text)
        case .checkpoint(let checkpoint):
            Label(
                "Checkpoint saved — \(checkpoint.summary)",
                systemImage: "camera.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notice(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct AssistantBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: 640, alignment: .leading)
            .lfCard()
            .textSelection(.enabled)
    }
}

private struct ToolCallRow: View {
    let invocation: ToolInvocation

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
            Text(invocation.name).font(.callout.monospaced().bold())
            Text(invocation.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

private struct ToolResultRow: View {
    let callID: UUID
    let output: String
    let failed: Bool
    let toolName: String?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Theme.danger : Theme.success)
                    Text(expanded ? "Hide output" : "Show output")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.borderless)

            if expanded {
                if toolName == "build_diagnostics" {
                    DiagnosticsCard(rawOutput: output)
                } else {
                    ScrollView {
                        Text(output)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 280)
                    .padding(8)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
            }
        }
    }
}

/// Parsed compiler diagnostics with breadcrumb navigation: an error timeline
/// on top, then groups by file with per-diagnostic location chips.
private struct DiagnosticsCard: View {
    let rawOutput: String

    private var diagnostics: [Diagnostic] {
        DiagnosticParser.parse(rawOutput)
    }

    var body: some View {
        let all = diagnostics
        let errors = all.filter { $0.severity == .error }
        let grouped = Dictionary(grouping: all, by: \.file)

        VStack(alignment: .leading, spacing: 8) {
            if all.isEmpty {
                Text(rawOutput)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                // Breadcrumb trail: file → line → severity for the first
                // error, plus the full error timeline.
                if let first = errors.first {
                    HStack(spacing: 6) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .foregroundStyle(Theme.danger)
                        Text(first.file)
                            .font(.caption.monospaced().bold())
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(location(first))
                            .font(.caption2.monospaced())
                        Spacer()
                        Text("\(errors.count) error\(errors.count == 1 ? "" : "s")")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.danger)
                    }
                    .padding(6)
                    .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }

                ForEach(grouped.keys.sorted(), id: \.self) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file)
                            .font(.caption.monospaced().bold())
                        ForEach(diagnostics.filter { $0.file == file }) { diagnostic in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(severityLabel(diagnostic.severity))
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(severityColor(diagnostic.severity))
                                Text(location(diagnostic))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(diagnostic.message)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(6)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                HStack {
                    Text("\(errors.count) errors, \(all.filter { $0.severity == .warning }.count) warnings, \(all.filter { $0.severity == .note }.count) notes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Raw output")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func severityLabel(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "error"
        case .warning: return "warning"
        case .note: return "note"
        }
    }

    private func severityColor(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return Theme.danger
        case .warning: return Theme.warning
        case .note: return Theme.textSecondary
        }
    }

    private func location(_ diagnostic: Diagnostic) -> String {
        [diagnostic.line.map(String.init) ?? "?", diagnostic.column.map(String.init) ?? "?"].joined(separator: ":")
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval needed", systemImage: "hand.raised.fill")
                .font(.headline)

            switch request.preview {
            case .command(let command):
                Text("Run command:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .textSelection(.enabled)
            case .diff(let diff, let path):
                Text("Edit \(path):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DiffPreview(diff: diff)
            case .none:
                Text(request.invocation.summary)
                    .font(.callout.monospaced())
            }

            HStack {
                // Approve is a deliberate act: Command-Return, never bare
                // Return (which could fire while typing elsewhere).
                Button("Approve ⌘↩") { onDecision(true) }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                Button("Decline", role: .destructive) { onDecision(false) }
                Spacer()
                if request.invocation.name == "run_command" {
                    Text("The command runs in the workspace after approval — never silently.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .lfWashCard(Theme.warning)
    }
}

private struct DiffPreview: View {
    let diff: DiffEngine.Result

    var body: some View {
        ScrollView {
            Text(diff.unified)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
                .overlay(alignment: .topLeading) {
                    Text("+\(diff.addedCount) −\(diff.removedCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
        }
        .frame(maxHeight: 320)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .foregroundStyle(diff.isEmpty ? Theme.textSecondary : Theme.textPrimary)
    }
}

private struct QuestionCard: View {
    let question: String
    let onAnswer: (String) -> Void

    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The agent has a question", systemImage: "questionmark.circle.fill")
                .font(.headline)
            Text(question)
                .font(.callout)
                .textSelection(.enabled)
            HStack {
                TextField("Your answer…", text: $answer)
                    .onSubmit {
                        guard !answer.isEmpty else { return }
                        onAnswer(answer)
                        answer = ""
                    }
                Button("Send") {
                    guard !answer.isEmpty else { return }
                    onAnswer(answer)
                    answer = ""
                }
                .disabled(answer.isEmpty)
            }
        }
        .padding(14)
        .lfWashCard(Theme.info)
    }
}

private struct FinishBanner: View {
    let reason: AgentFinish

    var body: some View {
        Group {
            switch reason {
            case .completed:
                Label("Task complete", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
            case .maxTurnsReached:
                Label("Reached the turn limit", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            case .declined:
                Label("Stopped — action declined", systemImage: "hand.raised.fill")
                    .foregroundStyle(Theme.warning)
            case .cancelled:
                Label("Stopped", systemImage: "stop.fill")
                    .foregroundStyle(Theme.textSecondary)
            case .engineError(let message):
                VStack(alignment: .leading) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(message).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .font(.callout.bold())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
}
/// Live streaming assistant output with a typing indicator.
private struct StreamingCard: View {
    let text: String

    @State private var dotIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == dotIndex ? Theme.accent : Theme.textSecondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .scaleEffect(index == dotIndex ? 1.2 : 0.8)
                }
                Text("Generating…")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: 640, alignment: .leading)
        .lfCard()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                dotIndex = (dotIndex + 1) % 3
            }
        }
    }
}
/// Collapsible chain-of-thought card.
private struct ReasoningCard: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "brain.head.profile" : "chevron.right.circle")
                        .foregroundStyle(Theme.accent)
                    Text(expanded ? "Hide reasoning" : "Reasoning")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.borderless)
            if expanded {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
        .padding(.vertical, 2)
    }
}
/// Plan-mode card: the agent's proposed plan with Approve / Revise.
private struct PlanCard: View {
    let plan: String
    let onDecision: (String?) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plan — approve before any tool runs", systemImage: "list.bullet.clipboard.fill")
                .font(.headline)
            Text(plan)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .textSelection(.enabled)
            HStack {
                // Command-Return only: Return must submit revision feedback,
                // never accidentally approve and execute.
                Button("Approve & Execute ⌘↩") { onDecision(nil) }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                TextField("Revise: feedback…", text: $feedback)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !feedback.isEmpty else { return }
                        onDecision(feedback)
                    }
                Button("Revise") {
                    guard !feedback.isEmpty else { return }
                    onDecision(feedback)
                }
                .disabled(feedback.isEmpty)
            }
        }
        .padding(14)
        .lfWashCard(Theme.accent)
    }
}
/// A removable attachment chip above the composer.
private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .font(.caption)
            Text(attachment.name)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surfaceInset, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}