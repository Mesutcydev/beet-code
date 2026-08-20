import AppKit
import SwiftUI

// MARK: - Composer

/// The composer: BeetCode's single input surface. One elevated card holding
/// the editor and the accessory row; above it, the per-turn Intent chips and
/// attachment chips appear only when they exist.
///
/// Design contract:
/// - No layout shift — intent editing lives in a popover anchored to the
///   Intent button; the card never moves.
/// - Enter sends, Shift+Enter inserts a newline, ⌘↩ sends too, Esc stops a
///   running agent (the only `.cancelAction` owner in the window).
/// - Send morphs into Stop while the agent runs.
/// - The signature gradient border traces the card's full perimeter and
///   tracks idle → focused → streaming.
struct ComposerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var store: ComposerStore

    @FocusState private var editorFocused: Bool

    private var phase: ComposerPhase {
        if controller.pendingApproval != nil
            || controller.pendingPlan != nil
            || controller.pendingQuestion != nil {
            return .awaitingApproval
        }
        if controller.isRunning { return .streaming }
        return editorFocused ? .focused : .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !store.selection.isEmpty {
                intentStrip
            }
            if !store.attachments.isEmpty {
                attachmentStrip
            }
            card
            if let hint = blockingHint {
                hintRow(hint)
            }
        }
        // The same centered column as the transcript above, so the input
        // sits directly under the conversation it belongs to.
        .frame(maxWidth: ContentColumn.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.bg)
    }

    // MARK: Card

    private var card: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ComposerHeader(
                    phase: phase,
                    store: store,
                    focusEditor: { editorFocused = true },
                    editor: editor)
                AccessoryRow(store: store)
                    .environmentObject(appState)
                    .environmentObject(controller)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ComposerCommitRail(store: store)
        }
        .padding(.leading, 16)
        .padding(.vertical, 14)
        .padding(.trailing, 10)
        .modifier(ComposerBorder(
            flow: settings.composerFlow,
            phase: phase,
            animated: settings.composerBorderAnimation && !reduceMotion))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The editor is the primary surface. The small status rail is deliberately
    /// typographic rather than an app icon, so the composer feels like a task
    /// instrument instead of another rounded card full of badges.
    private struct ComposerHeader<Editor: View>: View {
        let phase: ComposerPhase
        let store: ComposerStore
        let focusEditor: () -> Void
        let editor: Editor

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ComposerSignal(phase: phase)
                editor
                    .frame(height: 52, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                ComposerCommandMenu(store: store) {
                    focusEditor()
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var editor: some View {
        TextField("Describe a coding task…", text: Bindable(store).prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(AppFont.editor)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...4)
            .focused($editorFocused)
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
            .frame(height: 52, alignment: .topLeading)
            // Enter sends; Shift+Enter falls through to the field and
            // inserts a newline.
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.command) {
                    store.send()
                    return .handled
                }
                if settings.enterSends && !press.modifiers.contains(.shift) {
                    store.send()
                    return .handled
                }
                return .ignored
            }
            // Esc stops the agent while it runs; otherwise the key belongs
            // to whatever else wants it.
            .onKeyPress(.escape) {
                if controller.isRunning {
                    controller.stop()
                    return .handled
                }
                return .ignored
            }
            .accessibilityLabel("Task description")
    }

    // MARK: Strips

    /// The selected intent as removable chips — visible proof of what will
    /// be injected, without opening the picker.
    private var intentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(store.selection.orderedRoles) { role in
                    intentChip(
                        label: role.label, glyph: role.glyph, tint: Theme.accent,
                        help: role.instruction) {
                        store.toggleRole(role)
                    }
                }
                ForEach(store.selection.orderedFocus) { source in
                    intentChip(
                        label: source.label, glyph: source.glyph, tint: Theme.info,
                        help: source.summary) {
                        store.toggleFocus(source)
                    }
                }
                Button {
                    store.clearIntent()
                } label: {
                    Text("Clear")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove all roles and focus sources")
            }
            .padding(.horizontal, 2)
        }
    }

    private func intentChip(
        label: String, glyph: String, tint: Color,
        help: String, onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.wash(tint), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.washBorder(tint), lineWidth: 1))
        .help(help)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(store.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        store.attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Blocking hint

    /// Shown only when the user has something to send but can't — never a
    /// nag on an empty composer.
    private var blockingHint: String? {
        guard !controller.isRunning,
              !store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let blocker = store.sendBlocker,
              blocker != "Describe the task first"
        else { return nil }
        return blocker
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.warning)
            Text(text)
                .foregroundStyle(Theme.warning)
            if text.contains("model") {
                Button("Open Model Manager") {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }
}

// MARK: - Composer header

/// A compact state line. It gives the input a place in the product's
/// vocabulary without wasting the user's attention on a decorative logo.
private struct ComposerSignal: View {
    let phase: ComposerPhase

    private var tint: Color {
        switch phase {
        case .idle: Theme.textTertiary
        case .focused: Theme.accent
        case .streaming: Theme.info
        case .awaitingApproval: Theme.warning
        }
    }

    private var label: String {
        switch phase {
        case .idle: "READY"
        case .focused: "EDITING"
        case .streaming: "WORKING"
        case .awaitingApproval: "REVIEW"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text("TASK")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(tint)
        }
        .frame(width: 48, alignment: .leading)
        .padding(.top, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composer status")
        .accessibilityValue(label.capitalized)
    }
}

/// A deliberate command-deck affordance for the actions that are useful
/// before typing. It is a real Menu, not a visual flourish: presets, focus,
/// and draft clearing all operate on the same ComposerStore as the visible
/// controls below.
private struct ComposerCommandMenu: View {
    let store: ComposerStore
    let focusEditor: () -> Void

    var body: some View {
        Menu {
            Button {
                focusEditor()
            } label: {
                Label("Focus prompt", systemImage: "text.cursor")
            }

            Menu("Use an intent preset") {
                ForEach(IntentPresets.all) { preset in
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.glyph)
                    }
                }
            }

            Divider()

            Button("Clear prompt") {
                store.prompt = ""
            }
            .disabled(store.prompt.isEmpty)

            Button("Clear turn setup") {
                store.clearIntent()
                store.attachments = []
            }
            .disabled(store.selection.isEmpty && store.attachments.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .lfHoverLift()
        .help("Open composer commands and intent presets")
        .accessibilityLabel("Composer commands")
    }
}

// MARK: - Accessory row

/// The composer's lower rail is a single command line. Controls are separated
/// by hairlines, not nested boxes, so they read as one instrument and leave
/// the editor as the visual focus.
private struct AccessoryRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared

    let store: ComposerStore

    var body: some View {
        HStack(spacing: Spacing.sm) {
            AttachChip(store: store)

            AccessoryDivider()

            ModelSelectionPill()
                .environmentObject(appState)

            AccessoryDivider()

            IntentChipButton(store: store)
            SettingsToggleChip(
                title: "Plan", glyph: "list.bullet.clipboard",
                isOn: Binding(get: { settings.planMode }, set: { settings.planMode = $0 }),
                help: "Plan mode — the agent proposes a plan before any tool runs")
            SettingsToggleChip(
                title: "Reasoning", glyph: "brain.head.profile",
                isOn: Binding(get: { settings.showReasoning }, set: { settings.showReasoning = $0 }),
                help: "Show the model's chain-of-thought blocks in the transcript")

            Spacer(minLength: 8)

            ContextMeter(
                estimate: store.estimate,
                canCompact: store.canCompactHistory,
                compact: { controller.compactNow() })
        }
        .frame(minHeight: 28)
    }
}

/// The commit action is intentionally separated into a vertical rail. It
/// creates a clear final destination for the eye and gives the primary action
/// more room than a tiny arrow hidden among secondary controls.
private struct ComposerCommitRail: View {
    @EnvironmentObject private var controller: AgentSessionController
    let store: ComposerStore

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            SendStopButton(store: store)
        }
        .padding(.leading, 12)
        .frame(width: 106, alignment: .center)
    }
}

/// Thin vertical divider between accessory-row clusters.
private struct AccessoryDivider: View {
    var body: some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }
}

/// Paperclip pill — opens the file picker and appends attachments.
private struct AttachChip: View {
    let store: ComposerStore

    var body: some View {
        Button {
            attachFiles()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 11, weight: .medium))
                .lfComposerPill(active: false)
        }
        .buttonStyle(.plain)
        .help("Attach files or images — files are quoted into the message, images are described by the vision provider")
        .accessibilityLabel("Attach files")
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files or images"
        panel.message = "Files are quoted into the message; images are described by the vision provider."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls.prefix(8) {
                store.attachments.append(ComposerAttachment(url: url))
            }
        }
    }
}

// MARK: - Intent chip button

/// Opens the intent popover. Shows the live selection count and lights up
/// while any intent is selected or the popover is open.
private struct IntentChipButton: View {
    let store: ComposerStore
    @State private var showPicker = false

    var body: some View {
        let count = store.selection.count
        let active = count > 0 || showPicker
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .medium))
                Text("Intent")
                if count > 0 {
                    // A plain accent count — no badge-in-badge capsule.
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }
            .lfComposerPill(active: active)
        }
        .buttonStyle(.plain)
        .help("Intent — pick the agent's roles and context sources for this turn")
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            IntentPicker(store: store)
        }
    }
}

// MARK: - Settings toggle chip

/// One per-turn toggle (Plan, Reasoning) in the shared pill language.
private struct SettingsToggleChip: View {
    let title: String
    let glyph: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
            }
            .lfComposerPill(active: isOn)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Estimate (honest telemetry)

private struct ContextMeter: View {
    let estimate: ComposerStore.TokenEstimate
    let canCompact: Bool
    let compact: () -> Void

    var body: some View {
        Group {
            if estimate.requestTokens > 0 {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(text)
                        .foregroundStyle(tint)
                    if estimate.shouldCompact && canCompact {
                        Button(action: compact) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tint)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Compact older tool output before the next run")
                        .accessibilityLabel("Compact conversation context")
                    }
                }
                .help(helpText)
            }
        }
        .font(.caption2.monospacedDigit())
        // A reserved lane: monospaced digits + a fixed minimum width, so the
        // send button never shifts as the estimate appears, disappears or
        // grows.
        .frame(minWidth: 88, alignment: .trailing)
    }

    private var text: String {
        var text = "≈\(estimate.requestTokens.formatted()) tok"
        if let utilization = estimate.utilization, estimate.contextWindow != nil {
            text += " · \(max(1, Int((utilization * 100).rounded())))%"
        }
        return text
    }

    private var icon: String {
        if estimate.isOverBudget { return "exclamationmark.triangle.fill" }
        if estimate.shouldCompact { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }

    private var tint: Color {
        guard let utilization = estimate.utilization else { return Theme.textTertiary }
        if utilization >= 1 { return Theme.danger }
        if utilization >= 0.75 { return Theme.warning }
        if utilization >= 0.5 { return Theme.warning }
        return Theme.textTertiary
    }

    private var helpText: String {
        let parts = [
            "draft ≈\(estimate.draftTokens)",
            "intent ≈\(estimate.intentTokens)",
            "focus ≈\(estimate.focusTokens)",
            "attachments ≈\(estimate.attachmentTokens)",
        ]
        let breakdown = parts.joined(separator: " · ")
        if let window = estimate.contextWindow {
            let budget = max(1, window - estimate.responseReserve)
            let history = estimate.historyMessageCount == 0
                ? "no saved history"
                : "\(estimate.historyMessageCount) saved messages"
            return "Estimated request: ≈\(estimate.requestTokens.formatted()) tokens (current turn ≈\(estimate.totalTokens.formatted()), \(history)). Response reserve: \(estimate.responseReserve.formatted()). Safe request budget: \(budget.formatted()). System prompt and tool envelope add additional overhead."
        }
        return "Estimated current turn: \(breakdown). No percentage — this remote model's context window is unknown."
    }
}

// MARK: - Send / stop

/// Send morphs into Stop while the agent runs; the only `.cancelAction`
/// owner in the window, so Esc never conflicts.
private struct SendStopButton: View {
    @EnvironmentObject private var controller: AgentSessionController
    let store: ComposerStore

    var body: some View {
        if controller.isRunning {
            Button {
                controller.stop()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop")
                        .font(.caption.weight(.semibold))
                }
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 40)
                    .background(Theme.danger, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Stop the agent (Esc)")
            .accessibilityLabel("Stop the agent")
        } else {
            Button {
                store.send()
            } label: {
                HStack(spacing: 7) {
                    Text("Run")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                    .foregroundStyle(store.canSend ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.textTertiary))
                    .frame(width: 76, height: 40)
                    .background(
                        store.canSend ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceInset),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!store.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(store.canSend ? "Send (↩ or ⌘↩)" : store.sendBlocker ?? "Cannot send")
            .accessibilityLabel("Send")
        }
    }
}

// MARK: - Attachment chip

/// A removable attachment chip above the composer.
struct AttachmentChip: View {
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
        .lfHoverLift()
    }
}
