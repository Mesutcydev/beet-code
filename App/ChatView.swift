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
    @State private var sessionTitle = "New chat"

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            transcript
            Divider()
            ComposerView(store: composerStore)
                .environmentObject(controller)
        }
        .background { AtmosphereBackground() }
        .task {
            composerStore.attach(controller: controller, appState: appState)
        }
        .task(id: controller.activeSessionID) {
            let id = controller.activeSessionID
            let title = await Task.detached(priority: .utility) {
                guard let id, let record = SessionStore.shared.load(id: id) else {
                    return "New chat"
                }
                return SessionTitle.display(for: record)
            }.value
            guard !Task.isCancelled else { return }
            sessionTitle = title
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { providers in
            handlePaste(providers)
        }
    }

    /// A compact document bar for the conversation itself. It stays quieter
    /// than a toolbar, but gives restored/imported chats an identity and makes
    /// the current execution phase visible without opening the sidebar.
    private var chatHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(sessionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(controller.workspaceURL?.lastPathComponent ?? "Choose a workspace")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(phaseTint)
                    .frame(width: 6, height: 6)
                Text(phaseLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseTint)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(Theme.wash(phaseTint), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Chat phase")
            .accessibilityValue(phaseLabel)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 1)
        }
    }

    private var phaseLabel: String {
        switch controller.currentPhase {
        case .idle: "Ready"
        case .planning: "Planning"
        case .awaitingPlanApproval: "Review plan"
        case .working: "Working"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Needs answer"
        case .verifying: "Verifying"
        case .finished: "Finished"
        }
    }

    private var phaseTint: Color {
        switch controller.currentPhase {
        case .awaitingApproval, .awaitingPlanApproval, .awaitingQuestion: Theme.warning
        case .working, .planning, .verifying: Theme.info
        case .finished: Theme.success
        case .idle: Theme.textTertiary
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
                    if controller.isRunning, !controller.liveReasoningText.isEmpty {
                        LiveReasoningCard(
                            text: controller.liveReasoningText,
                            phase: controller.currentPhase)
                    }
                    if !controller.streamingText.isEmpty {
                        StreamingCard(text: controller.streamingText)
                    } else if controller.isReasoningVisible && controller.isRunning {
                        ReasoningIndicator()
                    }
                    if let approval = controller.pendingApproval {
                        ApprovalCard(request: approval) { approved, always in
                            controller.approve(approved, always: always)
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
                // Centered content column: readable on ultra-wide windows,
                // but wide enough that ordinary windows aren't left with
                // dead space on both sides of the conversation.
                .frame(maxWidth: ContentColumn.maxWidth, alignment: .leading)
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
                            // Opaque capsule + hairline, same voice as the
                            // suggestion chips — no floating material.
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .shadow(color: Theme.cardShadow, radius: 6, y: 2)
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: 0)

            // A proper identity tile instead of a bare SF Symbol: the app's
            // beet logo with a soft glow (danger variant when the last load
            // failed, so the two states are never confused).
            if case .failed = appState.enginePhase {
                emptyStateTile(
                    systemImage: "exclamationmark.triangle.fill",
                    fill: AnyShapeStyle(Theme.danger),
                    glow: Theme.danger)
            } else {
                Image("BeetLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 6)
            }

            Text(emptyTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Open a project folder, pick a downloaded model, and describe a coding task. Reads run automatically; every edit and command shows up here for approval.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

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

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateTile(
        systemImage: String, fill: AnyShapeStyle, glow: Color
    ) -> some View {
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .fill(fill)
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white))
            .shadow(color: glow.opacity(0.35), radius: 18, y: 6)
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
        case .idle: "Load a model to start"
        case .loading: "Loading model…"
        case .ready: "Describe a task"
        case .failed: "Model failed to load"
        }
    }

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

/// One rendered transcript row. Tool activity stays grouped, while reasoning
/// remains its own row so it is discoverable without opening the steps card.
private enum TranscriptRowModel: Identifiable {
    case user(AgentSessionController.TranscriptItem)
    case assistant(AgentSessionController.TranscriptItem)
    case toolSteps([AgentSessionController.TranscriptItem])
    case reasoning(AgentSessionController.TranscriptItem)
    case meta(AgentSessionController.TranscriptItem)

    var id: String {
        switch self {
        case .user(let item), .assistant(let item), .reasoning(let item), .meta(let item):
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
            case .toolCall, .toolResult:
                buffer.append(item)
            case .reasoning:
                flush(); rows.append(.reasoning(item))
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
        case .reasoning(let item):
            ReasoningCard(item: item)
        case .meta(let item):
            MetaRow(item: item)
        }
    }
}

/// User message: short prompts are a right-aligned pill (ChatGPT pattern);
/// long or multiline messages (pasted logs, imported Claude/Codex/Cursor
/// history) become a full-width left-aligned card — a narrow right pill
/// wastes the column and mangles preformatted text. The fill is the elevated
/// surface, not an accent wash: the 10 % wash read as pale pink on both
/// light and beet backgrounds.
private struct UserBubble: View {
    let item: AgentSessionController.TranscriptItem

    private static func isLongForm(_ text: String) -> Bool {
        text.contains("\n") || text.count > 280
    }

    var body: some View {
        if case .user(let text) = item.kind {
            if Self.isLongForm(text) {
                HStack {
                    Text(text)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(Theme.washBorder(Theme.accent), lineWidth: 1))
                        .frame(maxWidth: 760, alignment: .leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            } else {
                HStack {
                    Spacer()
                    Text(text)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(Theme.washBorder(Theme.accent), lineWidth: 1))
                        .frame(maxWidth: 520, alignment: .trailing)
                        .textSelection(.enabled)
                }
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

/// The agent's identity mark: the app's beet logo. Reused by assistant
/// messages and the streaming card so output always has a face.
struct AssistantAvatar: View {
    var size: CGFloat = 26

    var body: some View {
        Image("BeetLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
            .accessibilityHidden(true)
    }
}

/// Inline-markdown text with a plain-text fallback. Markdown renders code,
/// bold, and links like ChatGPT; if parsing fails (raw identifiers with
/// stray underscores), plain text shows — never a blank bubble. Set at
/// `.body` (not callout): the transcript is the app's primary reading
/// surface, so prose gets the full reading size.
struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        } else {
            Text(text)
                .font(.body)
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// One line inside the steps card: call, result (with inline output), or
/// reasoning.
private struct StepRow: View {
    let item: AgentSessionController.TranscriptItem
    @State private var outputExpanded = false

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
        default:
            EmptyView()
        }
    }
}

/// Reasoning is a transcript event in its own right, not another tool step.
/// The card is expanded by default so the feature is discoverable; the
/// disclosure keeps long traces from taking over the conversation.
private struct ReasoningCard: View {
    let item: AgentSessionController.TranscriptItem
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        guard case .reasoning(let value) = item.kind else { return "" }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: expanded ? "brain.head.profile" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24, height: 24)
                        .background(Theme.washStrong(Theme.accent), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reasoning")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(expanded ? "Visible model work" : "Tap to reveal the model's work")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text("\(text.count.formatted()) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 190)
                .padding(Spacing.sm)
                .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
        .padding(Spacing.md)
        .lfTranscriptCard(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reasoning")
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
                    .background(Theme.wash(Theme.danger), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
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
                                    .foregroundStyle(Theme.textTertiary)
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
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Raw output")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
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

/// Shared chrome for the transcript's interactive cards (approval, question,
/// plan): a tinted icon tile + semibold title + optional monospaced detail
/// chip — the same header language as Settings and the Model Manager.
private extension View {
    /// Raised surface + hairline + a 3-pt leading bar in the card's semantic
    /// tint. Quieter and more native than a full tint wash, and every
    /// interactive card shares the exact same silhouette.
    func lfTranscriptCard(_ tint: Color, radius: CGFloat = Radius.md) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Theme.surface, in: shape)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 4, y: 1)
    }
}

private struct TranscriptCardHeader: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Theme.washStrong(tint),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceInset, in: Capsule())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let onDecision: (Bool, Bool) -> Void

    /// Which "Always approve" scope this request belongs to — commands and
    /// edits widen different policy lanes, so the button says exactly what
    /// it will enable. Reads never ask, so they never appear here.
    private var isCommand: Bool {
        request.invocation.name == "run_command" || request.invocation.name == "build_diagnostics"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardHeader(
                title: "Approval needed",
                systemImage: "hand.raised.fill",
                tint: Theme.warning,
                detail: request.invocation.name)

            switch request.preview {
            case .command(let command):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Run command")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(command)
                        .font(.caption.monospaced())
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .textSelection(.enabled)
                }
            case .diff(let diff, let path):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Edit \(path)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    DiffPreview(diff: diff)
                }
            case .none:
                Text(request.invocation.summary)
                    .font(.caption.monospaced())
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    // Approve is a deliberate act: Command-Return, never bare
                    // Return (which could fire while typing elsewhere).
                    Button("Approve ⌘↩") { onDecision(true, false) }
                        .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    Button {
                        onDecision(true, true)
                    } label: {
                        Label(isCommand ? "Always approve safe commands" : "Always approve edits",
                              systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .help(isCommand
                        ? "Approve this and auto-approve policy-safe commands for this run and future runs"
                        : "Approve this and auto-approve file edits for this run and future runs")
                    Spacer(minLength: 0)
                    // Destructive lives at the far trailing edge, visually
                    // and motorically separated from the approve cluster.
                    Button("Decline", role: .destructive) { onDecision(false, false) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.danger)
                }
                if request.invocation.name == "run_command" {
                    Text("The command runs in the workspace after approval — never silently.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.warning)
    }
}

private struct DiffPreview: View {
    let diff: DiffEngine.Result
    @State private var split = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Text("+\(diff.addedCount)")
                    .foregroundStyle(Theme.success)
                Text("−\(diff.removedCount)")
                    .foregroundStyle(Theme.danger)
                Spacer()
                Picker("Diff layout", selection: $split) {
                    Text("Split").tag(true)
                    Text("Unified").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .controlSize(.mini)
                .labelsHidden()
            }
            .font(.caption2.monospaced().bold())
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            Divider().overlay(Theme.hairline)
            ScrollView {
                if split {
                    sideBySide
                } else {
                    Text(diff.unified)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(Spacing.sm)
                }
            }
            .frame(maxHeight: 320)
        }
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .foregroundStyle(diff.isEmpty ? Theme.textSecondary : Theme.textPrimary)
    }

    private var sideBySide: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.sideBySide.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    diffCell(row.left, kind: row.leftKind)
                    Divider().overlay(Theme.hairline)
                    diffCell(row.right, kind: row.rightKind)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func diffCell(_ text: String?, kind: DiffEngine.LineKind?) -> some View {
        Text(text ?? " ")
            .font(.caption.monospaced())
            .foregroundStyle(diffColor(kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 1)
            .background(diffFill(kind))
            .textSelection(.enabled)
    }

    private func diffColor(_ kind: DiffEngine.LineKind?) -> Color {
        switch kind {
        case .added: Theme.success
        case .removed: Theme.danger
        default: Theme.textPrimary
        }
    }

    private func diffFill(_ kind: DiffEngine.LineKind?) -> Color {
        switch kind {
        case .added: Theme.success.opacity(0.08)
        case .removed: Theme.danger.opacity(0.08)
        default: Color.clear
        }
    }
}

private struct QuestionCard: View {
    let question: String
    let onAnswer: (String) -> Void

    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardHeader(
                title: "The agent has a question",
                systemImage: "questionmark.circle.fill",
                tint: Theme.info)
            Text(question)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: Spacing.sm) {
                TextField("Your answer…", text: $answer)
                    .textFieldStyle(.roundedBorder)
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
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(answer.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.info)
    }
}

private struct FinishBanner: View {
    let reason: AgentFinish

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
    }

    /// Simple outcomes render as a tinted status pill; an engine error gets
    /// a rounded wash card so its detail message stays legible.
    @ViewBuilder
    private var content: some View {
        switch reason {
        case .completed:
            pill("Task complete", systemImage: "checkmark.seal.fill", tint: Theme.success)
        case .maxTurnsReached:
            pill("Reached the turn limit", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
        case .declined:
            pill("Stopped — action declined", systemImage: "hand.raised.fill", tint: Theme.warning)
        case .cancelled:
            pill("Stopped", systemImage: "stop.fill", tint: Theme.textSecondary)
        case .engineError(let message):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Error")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Theme.wash(Theme.danger), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.washBorder(Theme.danger), lineWidth: 1))
        }
    }

    private func pill(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background(Theme.wash(tint), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
    }
}
/// Live streaming assistant output: avatar-led (same identity as finished
/// messages), inline markdown, and a pulsing accent caret while generating.
/// Reduce Motion: the caret renders solid instead of pulsing.
private struct StreamingCard: View {
    let text: String

    @State private var caretVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Caret: a brand-gradient bar, pulsing while generating
                // (solid under Reduce Motion).
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 3, height: 16)
                    .opacity(caretVisible ? 1 : 0.25)
            }
            .textSelection(.enabled)
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.45)) {
                    caretVisible.toggle()
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }
}

/// Shown while the model works but has produced no visible prose yet
/// (reasoning blocks, tool-call wire format): a proper animated indicator
/// instead of raw filler ("thinking thinking…") or half-streamed JSON.
/// Reduce Motion: static text, no pulse.
private struct ReasoningIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantAvatar()
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                Text("Working…")
                    .font(.callout)
            }
            .foregroundStyle(Theme.textSecondary)
            .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.55))
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.7)) { pulse.toggle() }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }
        .accessibilityLabel("The model is working")
    }
}

/// Live reasoning card shown before or alongside the answer. It is compact by
/// design: useful progress is visible without continuously reflowing a full
/// height trace while tokens arrive.
private struct LiveReasoningCard: View {
    let text: String
    let phase: AgentPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            AssistantAvatar(size: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(Theme.accent)
                    Text(phaseLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("live")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.md)
        .lfTranscriptCard(Theme.accent)
        .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.92))
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.7)) { pulse.toggle() }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        .accessibilityLabel("Live reasoning: \(text)")
    }

    private var phaseLabel: String {
        switch phase {
        case .planning: "Planning"
        case .verifying: "Verifying"
        case .awaitingApproval: "Preparing an action"
        case .awaitingQuestion: "Thinking through a question"
        default: "Working through the task"
        }
    }
}
/// Plan-mode card: the agent's proposed plan with Approve / Revise.
private struct PlanCard: View {
    let plan: String
    let onDecision: (String?) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardHeader(
                title: "Plan — approve before any tool runs",
                systemImage: "list.bullet.clipboard.fill",
                tint: Theme.accent)
            Text(plan)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .textSelection(.enabled)
            HStack(spacing: Spacing.sm) {
                // Command-Return only: Return must submit revision feedback,
                // never accidentally approve and execute.
                Button("Approve & Execute ⌘↩") { onDecision(nil) }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
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
                .buttonStyle(.bordered)
                .disabled(feedback.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.accent)
    }
}
