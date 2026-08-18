import SwiftUI

// MARK: - Cell visual state

/// Every visual state a lattice cell can be in, each distinctly rendered.
enum LatticeCellVisualState: Equatable {
    case unavailable
    case available
    case suggested
    case selected
    case running
    case completed
    case failed
}

// MARK: - Main workspace view

/// The Intent Lattice screen: a structured agent-composition surface.
/// Docked like the simulator panel — the chat transcript stays visible.
struct IntentLatticeView: View {
    var store: IntentLatticeStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessionsRef: AgentSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowLabelWidth: CGFloat = 132
    private let columnHeaderWidth: CGFloat = 68
    private let cellSize: CGFloat = 44
    private let cellSpacing: CGFloat = 7
    private let maxContentWidth: CGFloat = 1240

    var body: some View {
        if store.isExpanded {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                composer
                Divider()
                footer
            }
            .background(Theme.bg)

        } else {
            collapsedBar
        }
    }

    // MARK: Collapsed summary (state fully preserved)

    private var collapsedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .foregroundStyle(Theme.accent)
            Text("Intent Lattice")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(store.collapsedSummary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if !store.validation.canRun, let blocker = store.validation.primaryBlocker {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                    .help(blocker)
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    store.isExpanded = true
                }
            } label: {
                Image(systemName: "chevron.up.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .help("Expand the Intent Lattice")
            .accessibilityLabel("Expand Intent Lattice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.bg)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .foregroundStyle(Theme.accent)
                Text("Intent Lattice")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Select which roles get which contexts for this task.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()

                // View switcher — belongs in the header, not a floating strip.
                Picker("View", selection: Bindable(store).activeView) {
                    ForEach(LatticeWorkspaceView.allCases) { view in
                        Text(view.label).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                // Collapse control with chevron — in the header.
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        store.isExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Collapse the lattice (state is preserved)")
                .accessibilityLabel("Collapse Intent Lattice")
            }

            // Real metrics — derived from the store, never fake.
            metricsRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var metricsRow: some View {
        HStack(spacing: 16) {
            metricChip(
                label: "Cells",
                value: store.selectedCellCount > 0 ? "\(store.selectedCellCount)" : "—",
                help: "Selected role × context cells")

            metricChip(
                label: "Est. tokens",
                value: store.projection.totalProjected > 0
                    ? "≈\(store.projection.totalProjected.formatted())" : "—",
                help: "Estimated prompt + context + reserved output tokens (≈ chars/4 heuristic)")

            metricChip(
                label: "Budget",
                value: budgetText,
                tint: budgetTint,
                help: "Projected tokens vs. the model's usable context window")

            if store.applicableSuggestions.count > 0 {
                Button("Apply \(store.applicableSuggestions.count) suggestion\(store.applicableSuggestions.count == 1 ? "" : "s")") {
                    store.applySuggestions()
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Deterministic prompt-analysis suggestions — applied only with this explicit action")
            }
        }
        .font(.caption)
    }

    private var budgetText: String {
        guard let utilization = store.projection.utilization else { return "—" }
        return "\(Int(utilization * 100))%"
    }

    private var budgetTint: Color {
        guard let utilization = store.projection.utilization else { return Theme.textSecondary }
        if utilization > 1.0 { return Theme.danger }
        if utilization >= 0.85 { return Theme.warning }
        return Theme.success
    }

    private func metricChip(label: String, value: String, tint: Color = Theme.textSecondary, help: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(tint)
        }
        .help(help)
    }

    // MARK: Content (adaptive)

    @ViewBuilder
    private var content: some View {
        switch store.activeView {
        case .lattice:
            latticeContent
        case .plan:
            PlanView(store: store)
        case .activity:
            ActivityView(store: store)
        }
    }

    private var latticeContent: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 860
            if wide {
                HStack(alignment: .top, spacing: 0) {
                    latticeGrid
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    InspectorPanel(store: store)
                        .frame(width: 280)
                }
            } else {
                VStack(spacing: 0) {
                    latticeGrid
                    Divider()
                    InspectorPanel(store: store)
                        .frame(maxHeight: 220)
                }
            }
        }
    }

    // MARK: Grid

    private var latticeGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: cellSpacing) {
                // Column headers
                HStack(spacing: cellSpacing) {
                    Color.clear.frame(width: rowLabelWidth, height: 24)
                    ForEach(ContextLayer.allCases) { layer in
                        VStack(spacing: 2) {
                            Image(systemName: layer.glyph)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            Text(layer.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(width: columnHeaderWidth)
                        .help(layer.description)
                    }
                }

                // Rows
                ForEach(LatticeRole.allCases) { role in
                    HStack(spacing: cellSpacing) {
                        // Row label
                        HStack(spacing: 5) {
                            Image(systemName: role.glyph)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                            Text(role.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(width: rowLabelWidth, alignment: .leading)
                        .help(role.summary)

                        // Cells
                        ForEach(ContextLayer.allCases) { context in
                            LatticeCellView(
                                store: store,
                                cellID: LatticeCellID(role, context),
                                size: cellSize,
                                isFocused: store.focusedCell == LatticeCellID(role, context))
                        }
                    }
                }
            }
            .padding(14)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [" "]) { _ in
            if let focused = store.focusedCell { store.toggle(focused) }
            return .handled
        }
        .onKeyPress(keys: ["\r", "\n"]) { _ in
            if let focused = store.focusedCell { store.selectedCell = focused }
            return .handled
        }
        .onKeyPress(.escape) {
            if store.selectedCell != nil {
                store.selectedCell = nil
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard let focused = store.focusedCell,
                  let digit = Int(String(press.characters)) else { return .ignored }
            store.setWeight(focused, Double(digit) / 10.0)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let current = store.focusedCell ?? LatticeCellID(.researcher, .openFiles)
            let roles = LatticeRole.allCases
            let contexts = ContextLayer.allCases
            guard let r = roles.firstIndex(of: current.role),
                  let c = contexts.firstIndex(of: current.context) else { return .ignored }
            var nr = r, nc = c
            switch press.key {
            case .leftArrow: nc = max(0, c - 1)
            case .rightArrow: nc = min(contexts.count - 1, c + 1)
            case .upArrow: nr = max(0, r - 1)
            case .downArrow: nr = min(roles.count - 1, r + 1)
            default: break
            }
            store.focusedCell = LatticeCellID(roles[nr], contexts[nc])
            return .handled
        }
    }

    // MARK: Integrated composer (primary input surface)

    @FocusState private var composerFocused: Bool

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                store.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    attachFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Attach files (grants Open Files context)")
                .accessibilityLabel("Attach files")

                TextField("Describe a coding task…", text: Bindable(store).prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...8)
                    .focused($composerFocused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(Theme.surfaceInset.opacity(composerFocused ? 0.8 : 0.5)))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(composerFocused ? Theme.accent.opacity(0.6) : Theme.hairline,
                                          lineWidth: 1))
                    .onKeyPress(.escape) {
                        if store.selectedCell != nil {
                            store.selectedCell = nil
                        } else {
                            store.isExpanded = false
                        }
                        return .handled
                    }

                if store.phase == .running || store.phase == .awaitingApproval {
                    Button(role: .destructive) {
                        store.cancelRun()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .help("Stop the run (Esc)")
                    .accessibilityLabel("Stop run")
                } else {
                    Button {
                        commit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(store.validation.canRun ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.textTertiary))
                            .frame(width: 30, height: 30)
                            .background(store.validation.canRun ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceInset),
                                        in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.validation.canRun)
                    .help(store.validation.canRun
                          ? "Run (⌘↩)"
                          : store.validation.primaryBlocker ?? "")
                    .accessibilityLabel("Run")
                }
            }

            // Presets + validation live WITH the composer, not floating.
            HStack(spacing: 8) {
                Menu {
                    ForEach(LatticePresets.all, id: \.id) { preset in
                        Button {
                            store.applyPreset(preset)
                        } label: {
                            Label(preset.name, systemImage: preset.glyph)
                        }
                    }
                    Divider()
                    Button("Clear selection") { store.clearAll() }
                } label: {
                    Label("Presets", systemImage: "rectangle.3.group")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Apply a preset — unavailable cells are skipped with an explanation")

                // Model pill: shows which engine runs the next message and
                // opens the switch popover without leaving the composer.
                ModelSelectionPill()
                    .environmentObject(appState)

                if !store.presetSkips.isEmpty {
                    Text("\(store.presetSkips.count) preset cell\(store.presetSkips.count == 1 ? "" : "s") skipped (unavailable)")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .help(store.presetSkips.map(\.reason).joined(separator: "\n"))
                }

                Spacer()

                if !store.validation.canRun, let blocker = store.validation.primaryBlocker {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Theme.warning)
                        Text(blocker)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .lineLimit(2)
                        if blocker.contains("Choose a model") {
                            Button("Choose Model") {
                                NotificationCenter.default.post(name: .openModelManager, object: nil)
                            }
                            .font(.caption2.weight(.medium))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func commit() {
        // Slash commands execute locally — never sent to the model.
        let text = store.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") {
            if sessionsRef.handleSlash(text) {
                store.prompt = ""
            }
            return
        }
        let outgoing = store.attachments
        let blocked = store.commitRun { manifest in
            sessionsRef.send(manifest, attachments: outgoing)
        }
        if blocked == nil {
            store.attachments = []
        }
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.attachments.append(ComposerAttachment(url: url))
            }
        }
    }

    // MARK: Footer — run validation + execution controls

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.validation.canRun, let blocker = store.validation.primaryBlocker {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    if blocker.contains("Choose a model") {
                        Button("Open Model Manager") {
                            NotificationCenter.default.post(name: .openModelManager, object: nil)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }

            HStack(spacing: 10) {
                // Plan mode + reasoning display: real agent-loop settings,
                // relocated here from the old floating accessory strip.
                Toggle(isOn: Binding(
                    get: { SettingsStore.shared.planMode },
                    set: { SettingsStore.shared.planMode = $0 }
                )) {
                    Label("Plan mode", systemImage: "list.bullet.clipboard")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("The agent proposes a plan before any tool runs")

                Toggle(isOn: Binding(
                    get: { SettingsStore.shared.showReasoning },
                    set: { SettingsStore.shared.showReasoning = $0 }
                )) {
                    Label("Reasoning", systemImage: "brain.head.profile")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show the model's chain-of-thought blocks in the transcript")

                Spacer()

                if store.phase == .running || store.phase == .awaitingApproval {
                    Button(role: .destructive) {
                        store.cancelRun()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Cancel the current run")
                } else {
                    Button {
                        commit()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .frame(minWidth: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.validation.canRun)
                    .help(store.validation.canRun
                          ? "Commit the lattice and start the agent (⌘↩)"
                          : store.validation.primaryBlocker ?? "")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Cell view

private struct LatticeCellView: View {
    var store: IntentLatticeStore
    let cellID: LatticeCellID
    let size: CGFloat
    var isFocused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: LatticeCellVisualState {
        let availability = store.availability(for: cellID.context)
        guard availability == .available else { return .unavailable }
        if let selection = store.configuration.selection(for: cellID) {
            _ = selection
            if store.phase == .running { return .running }
            if store.phase == .completed { return .completed }
            if store.phase == .failed { return .failed }
            return .selected
        }
        if store.applicableSuggestions.contains(cellID) { return .suggested }
        return .available
    }

    private var helpText: String {
        let availability = store.availability(for: cellID.context)
        if case .unavailable(let reason, let recovery) = availability {
            var text = "\(cellID.role.label) × \(cellID.context.label): \(reason)"
            if let recovery { text += " Recovery: \(recovery)" }
            return text
        }
        let weightText = store.configuration.selection(for: cellID).map {
            String(format: " — weight %.0f%%", $0.weight * 100)
        } ?? ""
        return "\(cellID.role.label) may use \(cellID.context.label)\(weightText). Click to toggle, Return for inspector."
    }

    var body: some View {
        Button {
            if store.configuration.isSelected(cellID) {
                store.selectedCell = cellID
            } else {
                store.toggle(cellID)
                store.selectedCell = cellID
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)

                if let selection = store.configuration.selection(for: cellID) {
                    // Weight indicator — a subtle arc proportional to weight.
                    WeightArc(weight: selection.weight)
                        .stroke(Theme.accent.opacity(0.7), lineWidth: 2)
                        .frame(width: size - 8, height: size - 8)
                }

                stateIcon
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                    .padding(-2)
            )
        }
        .buttonStyle(.plain)
        .disabled(state == .unavailable)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var fillColor: Color {
        switch state {
        case .unavailable: Theme.surfaceInset.opacity(0.4)
        case .available: Theme.surface
        case .suggested: Theme.accentSoft.opacity(0.5)
        case .selected: Theme.accentSoft
        case .running: Theme.info.opacity(0.12)
        case .completed: Theme.success.opacity(0.08)
        case .failed: Theme.danger.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch state {
        case .unavailable: Theme.hairline.opacity(0.4)
        case .available: Theme.hairline
        case .suggested: Theme.accent.opacity(0.45)
        case .selected: Theme.accent.opacity(0.8)
        case .running: Theme.info.opacity(0.6)
        case .completed: Theme.success.opacity(0.5)
        case .failed: Theme.danger.opacity(0.5)
        }
    }

    private var borderWidth: CGFloat {
        state == .selected || state == .running ? 1.5 : 1
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .selected, .completed:
            Image(systemName: state == .completed ? "checkmark" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .completed ? Theme.success : Theme.accent)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.danger)
        case .suggested:
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(0.6))
        default:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        "\(cellID.role.label) by \(cellID.context.label)"
    }

    private var accessibilityValue: String {
        switch state {
        case .unavailable: "Unavailable"
        case .available: "Available"
        case .suggested: "Suggested"
        case .selected: "Selected"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

private struct WeightArc: Shape {
    var weight: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let endAngle = Angle(degrees: -90 + weight * 360)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90), endAngle: endAngle, clockwise: false)
        return path
    }
}

// MARK: - Inspector panel

private struct InspectorPanel: View {
    var store: IntentLatticeStore

    var body: some View {
        Group {
            if let cellID = store.selectedCell {
                cellInspector(cellID)
            } else if let run = store.currentRun {
                runInspector(run)
            } else {
                emptyInspector
            }
        }
        .padding(12)
    }

    private var emptyInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No cell selected", systemImage: "square.dashed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Click a cell to select it, then click again or press Return to open its inspector. Cells show weight, availability, and per-cell instructions.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cellInspector(_ cellID: LatticeCellID) -> some View {
        let selection = store.configuration.selection(for: cellID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: cellID.role.glyph)
                    .foregroundStyle(Theme.accent)
                Text(cellID.role.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("×")
                    .foregroundStyle(Theme.textTertiary)
                Text(cellID.context.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    store.selectedCell = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Close inspector (Esc)")
            }

            Text(cellID.context.description)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let selection {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Weight")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text("\(Int(selection.weight * 100))%")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Slider(value: Binding(
                        get: { store.configuration.selection(for: cellID)?.weight ?? 0 },
                        set: { store.setWeight(cellID, $0) }
                    ), in: 0...1)
                    .accessibilityLabel("Cell weight")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instruction (optional)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Override instruction for this cell…", text: Binding(
                        get: { store.configuration.selection(for: cellID)?.note ?? "" },
                        set: { store.setNote(cellID, $0) }
                    ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .lineLimit(2...4)
                }

                let tokens = LatticeEngine.estimateTokens(
                    store.resolvedContextText(cellID.context))
                HStack {
                    Text("Context estimate")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(tokens > 0 ? "≈\(tokens) tokens" : "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }

                Button(role: .destructive) {
                    store.deselect(cellID)
                    store.selectedCell = nil
                } label: {
                    Label("Remove from configuration", systemImage: "minus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func runInspector(_ run: LatticeRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Run \(run.id.uuidString.prefix(8))", systemImage: "play.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Model: \(run.modelDisplayName)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Workspace: \(URL(fileURLWithPath: run.workspacePath).lastPathComponent)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Divider()
            ForEach(run.plan, id: \.role) { stage in
                HStack(spacing: 6) {
                    Image(systemName: (store.stageStatus[stage.role.rawValue] ?? .pending).glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(stageColor(stage.role))
                    Text(stage.role.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(stage.contexts.map(\.label).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stageColor(_ role: LatticeRole) -> Color {
        switch store.stageStatus[role.rawValue] ?? .pending {
        case .pending: Theme.textTertiary
        case .active: Theme.info
        case .completed: Theme.success
        case .failed: Theme.danger
        case .skipped: Theme.textTertiary
        }
    }
}

// MARK: - Plan view

private struct PlanView: View {
    var store: IntentLatticeStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.configuration.cells.isEmpty {
                    Text("No configuration yet. Select cells in the Lattice view or apply a preset to see the execution plan.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(store.configuration.activeRoles, id: \.self) { role in
                        let contexts = store.configuration.grantedContexts(for: role)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: role.glyph)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                Text(role.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                if role == .orchestrator {
                                    Text("coordination")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.info.opacity(0.12)))
                                        .foregroundStyle(Theme.info)
                                }
                                Spacer()
                                stageChip(role)
                            }
                            Text(role.instruction)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            if !contexts.isEmpty {
                                HStack(spacing: 4) {
                                    Text("Contexts:")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                    ForEach(contexts) { context in
                                        Text(context.label)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Theme.surfaceInset))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            if role == .builder || role == .tester {
                                Text("Terminal operations require approval.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    }

                    Text("Execution order: \(store.configuration.activeRoles.map(\.label).joined(separator: " → "))")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
        }
    }

    private func stageChip(_ role: LatticeRole) -> some View {
        let stage = store.stageStatus[role.rawValue] ?? .pending
        return Label(stage.rawValue.capitalized, systemImage: stage.glyph)
            .font(.caption2.weight(.medium))
            .foregroundStyle(stageTint(stage))
    }

    private func stageTint(_ stage: LatticeExecutionStage) -> Color {
        switch stage {
        case .pending: Theme.textTertiary
        case .active: Theme.info
        case .completed: Theme.success
        case .failed: Theme.danger
        case .skipped: Theme.textTertiary
        }
    }
}

// MARK: - Activity view

/// Decision log: real transcript events from the agent controller —
/// decisions, tool events, approvals, errors, outcomes. Never raw
/// hidden chain-of-thought.
private struct ActivityView: View {
    var store: IntentLatticeStore
    @EnvironmentObject private var sessions: AgentSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if sessions.transcript.isEmpty {
                    Text("No activity yet. Run a task from the Lattice view to see decisions, tool events, and outcomes here.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(sessions.transcript) { item in
                        ActivityRow(item: item)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActivityRow: View {
    let item: AgentSessionController.TranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var kind: AgentSessionController.TranscriptItem.Kind { item.kind }

    private var icon: String {
        switch kind {
        case .user: "arrow.up.circle"
        case .assistant: "text.bubble"
        case .toolCall: "wrench"
        case .toolResult(_, _, let failed, _): failed ? "xmark.circle" : "checkmark.circle"
        case .reasoning: "brain"
        case .checkpoint: "camera"
        case .notice: "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch kind {
        case .user: Theme.accent
        case .assistant: Theme.textSecondary
        case .toolCall: Theme.info
        case .toolResult(_, _, let failed, _): failed ? Theme.danger : Theme.success
        case .reasoning: Theme.textTertiary
        case .checkpoint: Theme.textSecondary
        case .notice: Theme.warning
        }
    }

    private var title: String {
        switch kind {
        case .user: "You"
        case .assistant: "Agent"
        case .toolCall(let invocation): "Tool: \(invocation.name)"
        case .toolResult(_, _, let failed, let toolName):
            (failed ? "Failed: " : "Result: ") + (toolName ?? "tool")
        case .reasoning: "Reasoning summary"
        case .checkpoint: "Checkpoint saved"
        case .notice: "Notice"
        }
    }

    private var summary: String {
        switch kind {
        case .user(let text): String(text.prefix(140))
        case .assistant(let text): String(text.prefix(140))
        case .toolCall(let invocation): invocation.summary
        case .toolResult(_, let output, _, _): String(output.prefix(140))
        case .reasoning(let text): String(text.prefix(140))
        case .checkpoint: ""
        case .notice(let text): String(text.prefix(140))
        }
    }
}
