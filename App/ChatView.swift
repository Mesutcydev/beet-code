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

    /// Single source of truth for the composer (prompt, attachments, intent
    /// selection). Owned by ChatView so it survives view rebuilds; attached
    /// to the live controller/AppState in `.task`.
    @State private var composerStore = ComposerStore()

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            ComposerView(store: composerStore)
                .environmentObject(controller)
        }
        .background(surfaceBackground)
        .task {
            composerStore.attach(controller: controller, appState: appState)
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { providers in
            handlePaste(providers)
        }
    }

    // MARK: Transcript

    @State private var isPinnedToBottom = true

    /// Cursor/ChatGPT-style transcript: a centered content column (never
    /// edge-to-edge prose), grouped tool steps, avatar-led assistant output.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if controller.transcript.isEmpty && controller.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(displayRows) { row in
                        rowView(row)
                            .id(row.id)
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
                // Centered content column: on wide windows the transcript
                // never stretches edge-to-edge (Cursor/ChatGPT both keep a
                // readable measure of ~760pt centered).
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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

            // ChatGPT-style quick prompts: one tap drops a ready-made task
            // into the composer. Only offered when a model can actually run
            // (no dead affordance on a failed/no-model state).
            if canSuggestPrompts {
                VStack(spacing: 10) {
                    suggestionRow(suggestions[0])
                    suggestionRow(suggestions[1])
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    /// Label (chip text) + prompt (what actually goes in the composer).
    private struct Suggestion: Identifiable {
        let label: String
        let prompt: String
        let glyph: String
        var id: String { label }
    }

    private var suggestions: [[Suggestion]] {
        [
            [
                Suggestion(label: "Explain this codebase",
                           prompt: "What does this project do? Walk me through the structure and the main entry points.",
                           glyph: "doc.text.magnifyingglass"),
                Suggestion(label: "Find bugs",
                           prompt: "Review this project for likely bugs and correctness problems. Report the top issues with file locations.",
                           glyph: "ladybug"),
            ],
            [
                Suggestion(label: "Fix the failing build",
                           prompt: "Run the build/tests and fix whatever fails. Explain each fix.",
                           glyph: "wrench.and.screwdriver"),
                Suggestion(label: "Add a feature",
                           prompt: "I want to add a new feature. First explore the codebase, then propose a plan before changing anything.",
                           glyph: "wand.and.stars"),
            ],
        ]
    }

    /// Suggestion chips make sense only when a run could actually start.
    private var canSuggestPrompts: Bool {
        switch appState.enginePhase {
        case .ready, .idle: return appState.activeModel != nil || appState.isRemoteActive || APIKeyStore.shared.configuredProviders.isEmpty == false
        case .loading, .failed: return false
        }
    }

    @ViewBuilder
    private func suggestionRow(_ items: [Suggestion]) -> some View {
        HStack(spacing: 10) {
            ForEach(items) { suggestion in
                Button {
                    composerStore.prompt = suggestion.prompt
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: suggestion.glyph)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text(suggestion.label)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .lfHoverLift()
                .help(suggestion.prompt)
            }
        }
    }

    private var emptyTitle: String {
        switch appState.enginePhase {
        case .idle: "No model loaded — open the Model Manager (⇧⌘M)"
        case .loading: "Loading model…"
        case .ready: "Ready — describe a task"
        case .failed: "Model failed to load — check the Model Manager"
        }
    }


    /// Deepest app surface behind the transcript.
    private var surfaceBackground: Color { Theme.bg }

    /// ⌘V: paste images (screenshots) or file URLs.
    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async {
                            composerStore.attachments.append(ComposerAttachment(url: url))
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
                                composerStore.attachments.append(ComposerAttachment(url: url, isImage: true))
                            }
                        }
                    }
                }
            }
        }
    }

}
// MARK: - Rows

/// One rendered transcript row. Consecutive tool activity (calls, results,
/// reasoning) collapses into a single "steps" card — the Cursor pattern —
/// so a run reads as "answer, work, answer", never a wall of alternating
/// call/result lines.
private enum TranscriptRowModel: Identifiable {
    case user(AgentSessionController.TranscriptItem)
    case assistant(AgentSessionController.TranscriptItem)
    case toolSteps([AgentSessionController.TranscriptItem])
    case meta(AgentSessionController.TranscriptItem)

    var id: String {
        switch self {
        case .user(let item), .assistant(let item), .meta(let item):
            return item.id.uuidString
        case .toolSteps(let items):
            return "steps-" + (items.first?.id.uuidString ?? "empty")
        }
    }
}

private extension ChatView {
    /// Groups the flat transcript into display rows.
    var displayRows: [TranscriptRowModel] {
        var rows: [TranscriptRowModel] = []
        var buffer: [AgentSessionController.TranscriptItem] = []
        func flush() {
            if !buffer.isEmpty {
                rows.append(.toolSteps(buffer))
                buffer = []
            }
        }
        for item in controller.transcript {
            switch item.kind {
            case .user:
                flush(); rows.append(.user(item))
            case .assistant:
                flush(); rows.append(.assistant(item))
            case .toolCall, .toolResult, .reasoning:
                buffer.append(item)
            case .checkpoint, .notice:
                flush(); rows.append(.meta(item))
            }
        }
        flush()
        return rows
    }

    @ViewBuilder
    func rowView(_ row: TranscriptRowModel) -> some View {
        switch row {
        case .user(let item):
            UserBubble(item: item)
        case .assistant(let item):
            AssistantMessage(item: item)
        case .toolSteps(let items):
            ToolStepsCard(items: items)
        case .meta(let item):
            MetaRow(item: item)
        }
    }
}

/// User message: right-aligned pill (ChatGPT pattern) with a max measure.
private struct UserBubble: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        if case .user(let text) = item.kind {
            HStack {
                Spacer()
                Text(text)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1))
                    .frame(maxWidth: 520, alignment: .trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Assistant output: avatar-led, no bubble, full column width, inline
/// markdown — the ChatGPT/Cursor reading pattern.
private struct AssistantMessage: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        if case .assistant(let text) = item.kind {
            HStack(alignment: .top, spacing: 12) {
                AssistantAvatar()
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The agent's identity mark: gradient tile with a sparkles glyph. Reused by
/// assistant messages and the streaming card so output always has a face.
struct AssistantAvatar: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.accentGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white))
            .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
            .accessibilityHidden(true)
    }
}

/// Inline-markdown text with a plain-text fallback. Markdown renders code,
/// bold, and links like ChatGPT; if parsing fails (raw identifiers with
/// stray underscores), plain text shows — never a blank bubble.
struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// Checkpoint + notice lines: quiet, centered, never shouting.
private struct MetaRow: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        switch item.kind {
        case .checkpoint(let checkpoint):
            Label("Checkpoint saved — \(checkpoint.summary)", systemImage: "camera.fill")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .notice(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        default:
            EmptyView()
        }
    }
}

/// Grouped tool activity: one collapsible card per consecutive run of
/// calls/results/reasoning. Header shows the step count + outcome; the
/// expanded body lists each step with status and inline output.
private struct ToolStepsCard: View {
    let items: [AgentSessionController.TranscriptItem]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var callCount: Int {
        items.filter { if case .toolCall = $0.kind { return true }; return false }.count
    }
    private var hasFailure: Bool {
        items.contains { if case .toolResult(_, _, let failed, _) = $0.kind { return failed }; return false }
    }
    private var toolNames: [String] {
        var names: [String] = []
        for item in items {
            if case .toolCall(let invocation) = item.kind, !names.contains(invocation.name) {
                names.append(invocation.name)
            }
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text("\(callCount) step\(callCount == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if !toolNames.isEmpty {
                        Text(toolNames.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if hasFailure {
                        Label("failed", systemImage: "xmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.success)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide tool steps" : "Show tool steps")

            if expanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        StepRow(item: item)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// One line inside the steps card: call, result (with inline output), or
/// reasoning.
private struct StepRow: View {
    let item: AgentSessionController.TranscriptItem
    @State private var outputExpanded = false
    @State private var reasoningExpanded = false

    var body: some View {
        switch item.kind {
        case .toolCall(let invocation):
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                Text(invocation.name)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(invocation.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .toolResult(_, let output, let failed, let toolName):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    outputExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? Theme.danger : Theme.success)
                        Text(outputExpanded ? "Hide output" : "Show output")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.borderless)

                if outputExpanded {
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
                        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    }
                }
            }
        case .reasoning(let text):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    reasoningExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: reasoningExpanded ? "brain.head.profile" : "chevron.right.circle")
                            .foregroundStyle(Theme.accent)
                        Text(reasoningExpanded ? "Hide reasoning" : "Reasoning")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.borderless)
                if reasoningExpanded {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
            }
        default:
            EmptyView()
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
/// Live streaming assistant output: avatar-led (same identity as finished
/// messages), inline markdown, and a blinking caret while generating.
/// Reduce Motion: the caret renders solid instead of blinking.
private struct StreamingCard: View {
    let text: String

    @State private var caretVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantAvatar()
            HStack(alignment: .top, spacing: 0) {
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Caret: blinks while generating (solid under Reduce Motion).
                Text("▍")
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                    .opacity(caretVisible ? 1 : 0)
            }
            .textSelection(.enabled)
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                caretVisible.toggle()
            }
        }
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