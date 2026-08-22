import AppKit
import SwiftUI

/// Compact document bar for the active conversation. It is a separate view so
/// streaming transcript updates do not rebuild toolbar/menu structure.
struct ChatHeaderView: View {
    let title: String
    let phaseLabel: String
    let phaseTint: Color
    let canReview: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(
                    Theme.wash(Theme.accent),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
            ChatHeaderActions(canReview: canReview)
            ChatPhaseBadge(label: phaseLabel, tint: phaseTint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 1)
        }
    }

}

struct ChatHeaderActions: View {
    let canReview: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button {
                post(.gitDiff)
            } label: {
                Label("Review", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(LFCapsuleButtonStyle())
            .lfHoverLift()
            .help("Review changed files")
            .disabled(!canReview)

            Menu {
                menuButton("Browser", "safari", .toggleBrowserPanel)
                menuButton("Simulator", "iphone", .toggleSimulatorPanel)
                menuButton("Diagnostics", "stethoscope", .toggleDiagnosticsPanel)
                Divider()
                Group {
                    menuButton("Git status", "circle.dashed", .gitStatus)
                    menuButton("Review changes", "doc.text.magnifyingglass", .gitDiff)
                    menuButton("Undo last checkpoint", "arrow.uturn.backward", .undoCheckpoint)
                }
                .disabled(!canReview)
                Divider()
                menuButton("Export as Markdown…", "doc.text", .exportChatMarkdown)
                menuButton("Export as JSON…", "curlybraces.square", .exportChatJSON)
                menuButton("Export task bundle…", "shippingbox", .exportTaskBundle)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceInset, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .lfHoverLift()
            .help("More workspace actions")
            .accessibilityLabel("More workspace actions")
        }
    }

    private func menuButton(
        _ title: LocalizedStringKey,
        _ icon: String,
        _ notification: Notification.Name
    ) -> some View {
        Button {
            post(notification)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func post(_ notification: Notification.Name) {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

struct ChatPhaseBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Theme.wash(tint), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat phase")
        .accessibilityValue(label)
    }
}

/// User message: short prompts are a right-aligned pill (ChatGPT pattern);
/// long or multiline messages (pasted logs, imported Claude/Codex/Cursor
/// history) become a full-width left-aligned card — a narrow right pill
/// wastes the column and mangles preformatted text. The fill is the elevated
/// surface, not an accent wash: the 10 % wash read as pale pink on both
/// light and beet backgrounds.
struct UserBubble: View {
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

/// Assistant output: avatar-led, no bubble, full column width, block-aware
/// markdown — lists, headings, and code blocks should read like an answer,
/// not like one flattened line of text.
struct AssistantMessage: View {
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

/// Markdown text with a plain-text fallback. Full parsing keeps headings,
/// lists, paragraphs, and fenced code blocks structurally separated; if
/// parsing fails (raw identifiers with stray underscores), plain text shows —
/// never a blank bubble. Set at `.body` (not callout): the transcript is the
/// app's primary reading surface, so prose gets the full reading size.
struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)) {
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
struct MetaRow: View {
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

/// One compact work log for a consecutive agent run. Cursor/Codex-style
/// activity grouping keeps reasoning and tool plumbing available for trust
/// and debugging without letting it compete with the final answer.
struct AgentActivityCard: View {
    let items: [AgentSessionController.TranscriptItem]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var callCount: Int {
        items.filter { if case .toolCall = $0.kind { return true }; return false }.count
    }
    private var hasFailure: Bool {
        items.contains { if case .toolResult(_, _, let failed, _) = $0.kind { return failed }; return false }
    }
    private var reasoningCount: Int {
        items.filter { if case .reasoning = $0.kind { return true }; return false }.count
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
    private var title: String {
        if callCount == 0 { return "Thought through the task" }
        return "\(callCount) action\(callCount == 1 ? "" : "s")"
    }
    private var summary: String {
        if !toolNames.isEmpty {
            return toolNames.map(Self.friendlyToolName).joined(separator: " · ")
        }
        return reasoningCount == 1 ? "Reasoning summary" : "Reasoning summaries"
    }

    private static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "read_file", "list_directory", "search", "find_files", "glob":
            "Explored code"
        case "write_file", "move_file", "apply_patch":
            "Edited files"
        case "run_command":
            "Ran command"
        case "build_diagnostics":
            "Checked build"
        case "sim_build_run":
            "Verified in Simulator"
        case "macos_build_run":
            "Built and launched"
        case "apple_ship":
            "Prepared release"
        case "task":
            "Specialist agent"
        default:
            name.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
                    Image(systemName: hasFailure ? "exclamationmark.circle.fill" : "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hasFailure ? Theme.danger : Theme.accent)
                        .frame(width: 22, height: 22)
                        .background(
                            Theme.washStrong(hasFailure ? Theme.danger : Theme.accent),
                            in: Circle())
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(expanded ? "Hide" : "Details")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide agent activity" : "Show reasoning and tool activity")

            if expanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        ActivityRow(item: item)
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

/// One event inside the activity disclosure. Prose uses the system face;
/// only commands and raw output use SF Mono.
struct ActivityRow: View {
    let item: AgentSessionController.TranscriptItem
    @State private var outputExpanded = false

    var body: some View {
        switch item.kind {
        case .toolCall(let invocation):
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
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
                        Text(resultButtonTitle(
                            expanded: outputExpanded,
                            failed: failed,
                            toolName: toolName))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.borderless)

                if outputExpanded {
                    if toolName == "build_diagnostics" {
                        DiagnosticsCard(rawOutput: output)
                    } else if toolName == "apple_ship" {
                        ShipResultCard(output: output, failed: failed)
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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14, height: 18)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        default:
            EmptyView()
        }
    }

    private func resultButtonTitle(
        expanded: Bool,
        failed: Bool,
        toolName: String?
    ) -> LocalizedStringKey {
        if expanded { return "Hide output" }
        if failed { return "Show failure" }
        switch toolName {
        case "apple_ship": return "Release prepared"
        case "task" where outputContainsIsolatedMerge: return "Isolated result merged"
        default: return "Show output"
        }
    }

    private var outputContainsIsolatedMerge: Bool {
        if case .toolResult(_, let output, _, _) = item.kind {
            return output.contains("Isolated worktree:")
        }
        return false
    }
}

struct ShipResultCard: View {
    let output: String
    let failed: Bool

    private var artifact: String? { value(after: "Artifact:") }
    private var report: String? { value(after: "Report:") }
    private var installedDevice: String? { value(after: "Installed:") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: failed ? "shippingbox.and.arrow.backward.fill" : "shippingbox.fill")
                    .foregroundStyle(failed ? Theme.danger : Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed ? "Release needs attention" : "Release artifact ready")
                        .font(.callout.weight(.semibold))
                    if let artifact {
                        Text(URL(fileURLWithPath: artifact).lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let installedDevice {
                        Label("Installed on \(installedDevice)", systemImage: "iphone.gen3.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer()
            }
            HStack(spacing: Spacing.sm) {
                if let artifact {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: artifact),
                        ])
                    } label: {
                        Label("Reveal artifact", systemImage: "folder")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
                if let report {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: report))
                    } label: {
                        Label("Open Ship Report", systemImage: "doc.text")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
            }
            Text(output)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
        .padding(Spacing.sm)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func value(after prefix: String) -> String? {
        output.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Parsed compiler diagnostics with breadcrumb navigation: an error timeline
/// on top, then groups by file with per-diagnostic location chips.
struct DiagnosticsCard: View {
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

struct TranscriptCardHeader: View {
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

struct ApprovalCard: View {
    let request: ApprovalRequest
    let onDecision: (Bool, Bool) -> Void

    /// Which "Always approve" scope this request belongs to — commands and
    /// edits widen different policy lanes, so the button says exactly what
    /// it will enable. Reads never ask, so they never appear here.
    private var isCommand: Bool {
        request.invocation.name == "run_command"
            || request.invocation.name == "build_diagnostics"
            || request.invocation.name == "apple_ship"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TranscriptCardHeader(
                title: "Approval required",
                systemImage: "hand.raised.fill",
                tint: Theme.warning,
                detail: request.invocation.name)

            switch request.preview {
            case .command(let command):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Command preview")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(command)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(1)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 1))
                        .fixedSize(horizontal: false, vertical: true)
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
                ViewThatFits(in: .horizontal) {
                    approvalButtonRow
                    approvalButtonColumn
                }
                if request.invocation.name == "run_command" {
                    Text("This command runs in the workspace only after you approve it.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.warning)
    }

    private var approvalButtonRow: some View {
        HStack(spacing: Spacing.sm) {
            approveButton
            alwaysAllowButton
            Spacer(minLength: 0)
            declineButton
        }
    }

    private var approvalButtonColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                approveButton
                alwaysAllowButton
            }
            declineButton
        }
    }

    private var approveButton: some View {
        // Approve is deliberate: Command-Return never fires while typing.
        Button {
            onDecision(true, false)
        } label: {
            Label("Approve", systemImage: "checkmark")
        }
        .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
    }

    private var alwaysAllowButton: some View {
        Button {
            onDecision(true, true)
        } label: {
            Label(isCommand ? "Always allow safe commands" : "Always allow edits",
                  systemImage: "checkmark.seal")
        }
        .buttonStyle(LFCapsuleButtonStyle())
        .help(isCommand
            ? "Approve this and auto-approve policy-safe commands for this run and future runs"
            : "Approve this and auto-approve file edits for this run and future runs")
    }

    private var declineButton: some View {
        // Destructive stays separated from the approval cluster.
        Button("Decline", role: .destructive) { onDecision(false, false) }
            .buttonStyle(LFCapsuleButtonStyle(tone: .destructive))
    }
}

struct DiffPreview: View {
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
            ForEach(diff.sideBySide) { row in
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

struct QuestionCard: View {
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
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .disabled(answer.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.info)
    }
}

struct CompletionSnapshot: Equatable {
    let actionCount: Int
    let changedFileCount: Int
    let checksPassed: Int
    let checksFailed: Int
    let artifact: String?
    let report: String?

    static func make(
        transcript: [AgentSessionController.TranscriptItem]
    ) -> CompletionSnapshot {
        let start = transcript.lastIndex { item in
            if case .user = item.kind { return true }
            return false
        }.map { transcript.index(after: $0) } ?? transcript.startIndex
        let items = transcript[start...]
        var actions = 0
        var files = Set<String>()
        var passed = 0
        var failed = 0
        var artifact: String?
        var report: String?

        for item in items {
            switch item.kind {
            case .toolCall(let invocation):
                actions += 1
                let arguments = TolerantJSON.value(from: invocation.argumentsJSON)?.objectValue
                switch invocation.name {
                case "write_file", "apply_patch":
                    if let path = arguments?["path"]?.stringValue { files.insert(path) }
                case "move_file":
                    if let path = arguments?["from"]?.stringValue { files.insert(path) }
                    if let path = arguments?["to"]?.stringValue { files.insert(path) }
                default:
                    break
                }
            case .toolResult(_, let output, let didFail, let toolName):
                guard let toolName else { continue }
                if Self.isCheckTool(toolName) {
                    if didFail { failed += 1 } else { passed += 1 }
                }
                if toolName == "apple_ship" {
                    artifact = Self.value(after: "Artifact:", in: output) ?? artifact
                    report = Self.value(after: "Report:", in: output) ?? report
                }
            default:
                break
            }
        }

        return CompletionSnapshot(
            actionCount: actions,
            changedFileCount: files.count,
            checksPassed: passed,
            checksFailed: failed,
            artifact: artifact,
            report: report)
    }

    private static func isCheckTool(_ name: String) -> Bool {
        ["build_diagnostics", "sim_build_run", "macos_build_run", "apple_ship"]
            .contains(name)
    }

    private static func value(after prefix: String, in output: String) -> String? {
        output.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct FinishBanner: View {
    let reason: AgentFinish
    let summary: CompletionSnapshot

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
            completionCard
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

    private var completionCard: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: summary.artifact == nil ? "checkmark.seal.fill" : "shippingbox.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.success)
                .frame(width: 38, height: 38)
                .background(Theme.washStrong(Theme.success), in: Circle())

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(completionTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.md) { completionMetrics }
                    VStack(alignment: .leading, spacing: Spacing.xs) { completionMetrics }
                }

                if summary.artifact != nil || summary.report != nil {
                    HStack(spacing: Spacing.sm) {
                        if let artifact = summary.artifact {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: artifact),
                                ])
                            } label: {
                                Label("Reveal artifact", systemImage: "folder")
                            }
                            .buttonStyle(LFCapsuleButtonStyle())
                        }
                        if let report = summary.report {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: report))
                            } label: {
                                Label("Open Ship Report", systemImage: "doc.text")
                            }
                            .buttonStyle(LFCapsuleButtonStyle())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: 680, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Theme.success)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var completionMetrics: some View {
        if summary.actionCount > 0 {
            metric(
                "\(summary.actionCount) action\(summary.actionCount == 1 ? "" : "s")",
                icon: "bolt")
        }
        if summary.changedFileCount > 0 {
            metric(
                "\(summary.changedFileCount) file\(summary.changedFileCount == 1 ? "" : "s") changed",
                icon: "doc.badge.ellipsis")
        }
        if summary.checksPassed > 0 {
            metric(
                "\(summary.checksPassed) check\(summary.checksPassed == 1 ? "" : "s") passed",
                icon: "checkmark.circle",
                tint: Theme.success)
        }
        if summary.checksFailed > 0 {
            metric(
                "\(summary.checksFailed) check\(summary.checksFailed == 1 ? "" : "s") failed",
                icon: "xmark.circle",
                tint: Theme.danger)
        }
        if summary.artifact != nil {
            metric("Release packaged", icon: "shippingbox", tint: Theme.success)
        }
        if summary.actionCount == 0,
           summary.changedFileCount == 0,
           summary.checksPassed == 0,
           summary.checksFailed == 0,
           summary.artifact == nil {
            metric("Completed", icon: "checkmark")
        }
    }

    private var completionTitle: LocalizedStringKey {
        if summary.artifact != nil { return "Release ready" }
        if summary.changedFileCount > 0 { return "Changes ready for review" }
        return "Task complete"
    }

    private func metric(
        _ title: LocalizedStringKey,
        icon: String,
        tint: Color = Theme.textSecondary
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
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
struct StreamingCard: View {
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
struct ReasoningIndicator: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantAvatar()
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Working…")
                    .font(.callout)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityLabel("The model is working")
    }
}

/// Live activity is a slim native status capsule, not a second answer card.
/// The complete trace remains available in the finished activity disclosure.
struct LiveReasoningCard: View {
    let text: String
    let phase: AgentPhase

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.45 : 1)
            Text(phaseLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(progressExcerpt)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(Theme.surface.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline.opacity(0.75), lineWidth: 1))
        .frame(maxWidth: 620, alignment: .leading)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.7)) { pulse.toggle() }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phaseLabel): \(progressExcerpt)")
    }

    private var progressExcerpt: String {
        let normalized = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .last ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 260 else { return normalized }
        return "…" + String(normalized.suffix(259))
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
struct PlanCard: View {
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
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
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
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(feedback.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .padding(.leading, Spacing.sm)
        .lfTranscriptCard(Theme.accent)
    }
}
