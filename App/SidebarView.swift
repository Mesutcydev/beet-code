import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @Environment(\.dismiss) private var dismiss
    @Binding var showRemoteAccess: Bool
    /// The compact portrait sidebar is presented as a sheet, so it must offer
    /// an explicit escape hatch in addition to Escape and the window chrome.
    var showsCloseButton: Bool = false
    // Sessions are decrypted OFF the main thread: loadAll() does Keychain +
    // AES-GCM per file, which blocked body evaluation (and hung the app when
    // the ad-hoc build raised a Keychain prompt). The list renders from
    // async-loaded state instead.
    @State private var recentSessions: [SessionRecord] = []
    /// Sidebar list selection IS the session switch: rows are tagged with
    /// their record id and onChange restores the picked session. Native
    /// selection gives the rows a real selected state (plain Buttons inside
    /// a sidebar List had no visible selection and failed silently).
    @State private var selectedSessionID: UUID?
    /// Shown when a picked session can't be restored (e.g. its project
    /// folder no longer exists) instead of the old silent no-op.
    @State private var sessionRestoreError: String?
    /// Which history the list shows: BeetCode's own sessions or chats
    /// imported from Claude / Codex / Cursor.
    @State private var sidebarTab: SidebarHistoryTab = .sessions
    @State private var isImporting = false
    @State private var isImportingBundle = false
    @State private var importSummary: String?
    @State private var importSummaryIsWarning = false
    /// Live parser feedback while an import runs (source + file + count).
    @State private var importStatus: String?
    @State private var hasAutoImported = false
    @State private var historySearch = ""
    @State private var pinnedSessionIDs: Set<UUID> = []

    private enum TaskStatus: Equatable {
        case running(String)
        case review
        case completed
        case stopped
        case idle
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(
                workspaceURL: sessions.workspaceURL,
                sidebarTab: sidebarTab,
                importedCount: recentSessions.count(where: { $0.source != .app }),
                historySearch: $historySearch,
                queuedTasks: pendingQueueTasks,
                isImporting: isImporting,
                isImportingBundle: isImportingBundle,
                showsCloseButton: showsCloseButton,
                onChooseWorkspace: chooseWorkspace,
                onImport: runImport,
                onImportTaskBundle: runTaskBundleImport,
                onRefresh: { Task { await reloadSessions() } },
                onNewSession: {
                    sessions.newSession()
                    selectedSessionID = nil
                    sidebarTab = .sessions
                },
                onSelectTab: { sidebarTab = $0 },
                onRunNext: { appState.drainTaskQueue() },
                onRemoveQueuedTask: { appState.removeQueuedTask($0) },
                onClose: { dismiss() }
            )
            Divider().overlay(Theme.hairline)
            List(selection: $selectedSessionID) {
                if sidebarTab == .sessions {
                    ownSections
                } else {
                    importedSections
                }
            }
            .listStyle(.sidebar)
            // The system list material is neutral; the explicit background
            // keeps the sidebar in the same visual world as Beet mode while
            // the rows themselves provide the elevation and selection cues.
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            // Tool destinations live in the conversation top bar now; keep
            // the bottom edge free so the chat list gets the full height.
            Color.clear.frame(height: 8)
        }
        .background(Theme.bg)
        .onExitCommand {
            guard showsCloseButton else { return }
            dismiss()
        }
        // Selection IS the restore: picking a tagged row switches to that
        // session (and reports why when it can't — no more silent no-ops).
        .onChange(of: selectedSessionID) { _, newValue in
            selectSession(newValue)
        }
        // First visit to the Imported tab runs one automatic import; later
        // visits are free until the user presses re-import.
        .onChange(of: sidebarTab) { _, newTab in
            if newTab == .imported && !hasAutoImported {
                hasAutoImported = true
                if !recentSessions.contains(where: { $0.source != .app }) {
                    runImport()
                }
            }
        }
        // Off-main load + reload whenever a session is saved (controller
        // publishes transcript/session changes through objectWillChange).
        .task { await reloadSessions() }
        .onReceive(sessions.objectWillChange) { _ in
            // Throttled: objectWillChange also fires per streamed token, and
            // a full decrypt-all pass per token would melt the disk.
            let now = Date()
            guard now.timeIntervalSince(lastSessionReload) > 2 else { return }
            lastSessionReload = now
            Task { await reloadSessions() }
        }
    }

    private var pendingQueueTasks: [QueuedAgentTask] {
        appState.queuedTasks.filter { !$0.state.isTerminal }
    }

    // MARK: Sidebar footer

    /// Tool destinations stay in the sidebar, but are named and grouped so
    /// they read as part of the navigation model rather than as unexplained
    /// floating glyphs in a second rail.
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 4) {
                footerTool("Models", icon: "cpu", isActive: false) {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
                footerTool("Settings", icon: "gearshape", isActive: false) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Menu {
                    Button("Remote sessions…") { showRemoteAccess = true }
                    Divider()
                    Button("Export current chat…") { exportCurrentChat() }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                        Text("More")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .help("More tools and app actions")
                .accessibilityLabel("More tools and app actions")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(Theme.surface.opacity(0.28))
    }

    private func footerTool(_ title: String, icon: String, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isActive ? Theme.wash(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .lfHoverLift()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: Own sessions

    @ViewBuilder
    private var ownSections: some View {
        if needsKeychainUnlock || sessionRestoreError != nil {
            Section {
            if needsKeychainUnlock {
                HStack(spacing: Spacing.sm) {
                    Text("History is locked")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Unlock") {
                        if SessionCrypto.unlockInteractively() {
                            needsKeychainUnlock = false
                            Task { await reloadSessions() }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let restoreError = sessionRestoreError {
                Label(restoreError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(3)
            }
            }
        }

        if sessions.workspaceURL != nil {
            Section {
                if let output = sessions.gitOutput {
                    ScrollView {
                        Text(output)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
            } header: {
                SidebarGroupHeader(
                    icon: "folder.fill",
                    appIcon: sessions.workspaceURL.flatMap { AppIconLookup.workspace($0.path) },
                    name: sessions.workspaceURL?.lastPathComponent ?? "Project",
                    count: nil)
            }
        }

        let own = visibleOwnSessions
        if own.isEmpty, !needsKeychainUnlock {
            Section {
                ownHistoryEmptyState
            }
        } else {
            ForEach(projectGroups(own)) { group in
                collapsibleGroup(key: "own:" + group.key, icon: group.icon,
                                 name: group.name, records: group.records,
                                 workspacePath: group.key, subtitle: nil)
            }
        }

    }

    private var ownHistoryEmptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Your work will stay close")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Chats are saved locally and grouped by project as soon as you start a task.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var visibleOwnSessions: [SessionRecord] {
        let own = recentSessions.filter { $0.source == .app }
        return own.filter { matchesSearch($0) }
    }

    private func matchesSearch(_ record: SessionRecord) -> Bool {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        if SessionTitle.display(for: record).lowercased().contains(query) { return true }
        if record.workspacePath.lowercased().contains(query) { return true }
        return record.messages.contains {
            $0.role == .user && $0.content.lowercased().contains(query)
        }
    }

    private func taskStatus(for record: SessionRecord) -> TaskStatus {
        if record.id == sessions.activeSessionID {
            if sessions.isRunning {
                return .running(phaseLabel(sessions.currentPhase))
            }
            if let finishReason = sessions.finishReason {
                switch finishReason {
                case .completed:
                    return .completed
                case .cancelled:
                    return .stopped
                case .declined, .maxTurnsReached, .engineError:
                    return .review
                }
            }
        }

        if let verification = record.messages.reversed().first(where: {
            $0.toolName == "build_diagnostics"
        }), verificationFailed(verification.content) {
            return .review
        }
        if let lastTool = record.messages.reversed().first(where: {
            $0.role == .toolResult
        }), lastTool.content.hasPrefix("error:") {
            return .review
        }
        return record.messages.contains(where: { $0.role == .assistant }) ? .completed : .idle
    }

    private func verificationFailed(_ output: String) -> Bool {
        output.hasPrefix("error:") || output.contains("exit status ")
    }

    private func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .planning, .awaitingPlanApproval: "Planning"
        case .working: "Running"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Waiting for you"
        case .verifying: "Verifying"
        case .idle, .finished: "Running"
        }
    }

    private func taskStatusTitle(_ status: TaskStatus) -> String? {
        switch status {
        case .running(let label): label
        case .review: "Review"
        case .stopped: "Stopped"
        case .completed, .idle: nil
        }
    }

    private func taskStatusIcon(_ status: TaskStatus) -> String {
        switch status {
        case .running: "circle.fill"
        case .review: "exclamationmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    private func taskStatusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .running: Theme.accent
        case .review: Theme.warning
        case .stopped: Theme.textTertiary
        case .completed: Theme.success
        case .idle: Theme.textTertiary
        }
    }

    private func workspacePathLabel(_ path: String) -> String {
        guard !path.isEmpty else { return "No workspace" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "Home" }
        return path
    }

    private func togglePinned(_ record: SessionRecord) {
        var updated = pinnedSessionIDs
        if updated.contains(record.id) {
            updated.remove(record.id)
        } else {
            updated.insert(record.id)
        }
        var preferences = AppPreferencesStore.shared.current
        preferences.pinnedSessionIDs = updated.sorted { $0.uuidString < $1.uuidString }
        AppPreferencesStore.shared.save(preferences)
        pinnedSessionIDs = updated
    }

    private func sortedTasks(_ records: [SessionRecord]) -> [SessionRecord] {
        records.sorted {
            let lhsPinned = pinnedSessionIDs.contains($0.id)
            let rhsPinned = pinnedSessionIDs.contains($1.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: Imported history

    @ViewBuilder
    private var importedSections: some View {
        if isImporting, let importStatus {
            Section {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(importStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.wash(Theme.info), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.washBorder(Theme.info), lineWidth: 1))
                .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else if let importSummary {
            let foundNothing = importSummary.hasPrefix("No ")
            let warningSummary = importSummaryIsWarning || foundNothing
            let summaryTint = warningSummary ? Theme.warning : Theme.success
            Section {
                Label(importSummary, systemImage: warningSummary ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(summaryTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.wash(summaryTint), in: Capsule())
                    .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }

        let imported = recentSessions.filter { $0.source != .app }
        if imported.isEmpty {
            Section {
                importedEmptyState
            }
        } else {
            Section {
                importSourceBar(imported)
            }

            let filtered = visibleImported(imported)
            if filtered.isEmpty {
                Section {
                    emptySearchState(historySearch.isEmpty
                                     ? "No chats from \(sourceFilter?.label ?? "this tool")."
                                     : "No chats match “\(historySearch)”.")
                }
            } else {
                ForEach(projectGroups(filtered)) { group in
                    collapsibleGroup(key: "import-project:" + group.key,
                                     icon: group.icon,
                                     name: group.name,
                                     records: group.records,
                                     workspacePath: group.key,
                                     subtitle: { $0.source.label })
                }
            }
        }
    }

    private var importedEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Continue work from other tools")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Find Claude, Codex, and Cursor chats, then organize them by project. Everything stays on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                runImport()
            } label: {
                Label("Scan for chats", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            .disabled(isImporting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func emptySearchState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }

    private func importSourceBar(_ imported: [SessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Filter by source")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(imported.count) chats")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    sourcePill(source: nil, label: "All", icon: "tray.full", count: imported.count)
                    ForEach(importSources, id: \.self) { source in
                        sourcePill(source: source, label: source.label,
                                   icon: source.systemImage,
                                   count: imported.filter { $0.source == source }.count)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func visibleImported(_ imported: [SessionRecord]) -> [SessionRecord] {
        let sourced = sourceFilter == nil ? imported : imported.filter { $0.source == sourceFilter }
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sourced }
        return sourced.filter { record in
            if SessionTitle.display(for: record).lowercased().contains(query) { return true }
            if record.workspacePath.lowercased().contains(query) { return true }
            return record.messages.contains {
                $0.role == .user && $0.content.lowercased().contains(query)
            }
        }
    }

    /// Whole-header expand/collapse. Native `Section(isExpanded:)` only
    /// toggles from the trailing chevron; a click on the plate must work too.
    @ViewBuilder
    private func collapsibleGroup(
        key: String,
        icon: String,
        name: String,
        records: [SessionRecord],
        workspacePath: String? = nil,
        subtitle: ((SessionRecord) -> String)? = nil
    ) -> some View {
        let expanded = !collapsedProjects.contains(key)
        let path = workspacePath ?? key
        let appIcon = AppIconLookup.header(path: path, records: records)
        Section {
            if expanded {
                ForEach(records) { record in
                    sessionRow(record, subtitle: subtitle?(record))
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded {
                        collapsedProjects.insert(key)
                    } else {
                        collapsedProjects.remove(key)
                    }
                }
            } label: {
                SidebarGroupHeader(
                    icon: icon, appIcon: appIcon,
                    name: name, count: records.count, expanded: expanded)
            }
            .buttonStyle(.plain)
        }
    }

    /// Claude, Codex and Cursor always appear as import sources — even at
    /// count 0 — so Cursor is never hidden behind “only sources we found”.
    private var importSources: [SessionSource] { [.claude, .codex, .cursor, .bundle] }

    /// One source-filter pill: icon + label + count, accent-highlighted
    /// while active. `source == nil` is the "All" pill.
    private func sourcePill(source: SessionSource?, label: String,
                            icon: String, count: Int) -> some View {
        let isActive = sourceFilter == source
        let tint = source.map(sourceTint) ?? Theme.info
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                sourceFilter = source
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption2.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
            }
            .foregroundStyle(isActive ? tint : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(isActive ? Theme.wash(tint) : Theme.surfaceInset.opacity(0.62),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(
                isActive ? Theme.washBorder(tint) : Color.clear,
                lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityLabel("\(label), \(count) chats")
    }

    /// Active source filter for the Imported tab: nil = all tools.
    @State private var sourceFilter: SessionSource?

    /// Which imported-project groups are collapsed. Lives in view state —
    /// a convenience, not data worth persisting.
    @State private var collapsedProjects: Set<String> = []

    /// One imported-chat section: a project folder with its chats, newest
    /// activity first. Chats whose source recorded no folder (or just the
    /// home directory) collect under "No project folder" instead of faking
    /// a project name.
    private struct ProjectGroup: Identifiable {
        let key: String
        let name: String
        let icon: String
        let latest: Date
        let records: [SessionRecord]
        var id: String { key }
    }

    private func projectGroups(_ records: [SessionRecord]) -> [ProjectGroup] {
        var byPath: [String: [SessionRecord]] = [:]
        for record in records { byPath[record.workspacePath, default: []].append(record) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return byPath.map { path, group in
            let sorted = sortedTasks(group)
            let unknown = path.isEmpty || path == home
            return ProjectGroup(
                key: path,
                name: unknown ? "No project folder" : URL(fileURLWithPath: path).lastPathComponent,
                icon: unknown ? "tray" : "folder.fill",
                latest: sorted.first?.updatedAt ?? .distantPast,
                records: sorted)
        }
        .sorted { $0.latest > $1.latest }
    }

    /// One session row — tagged for List selection, marked and explained
    /// when its project folder is gone. `subtitle` prefixes the metadata
    /// line (used to badge the import source).
    private func sessionRow(_ record: SessionRecord, subtitle: String?) -> some View {
        let status = taskStatus(for: record)
        let workspaceAvailable = SessionStore.shared.validateWorkspaceBinding(record)
        return SessionHistoryRow(
            record: record,
            subtitle: subtitle,
            selected: selectedSessionID == record.id,
            pinned: pinnedSessionIDs.contains(record.id),
            sourceTint: sourceTint(record.source),
            statusTitle: taskStatusTitle(status),
            statusIcon: taskStatusIcon(status),
            statusColor: taskStatusColor(status),
            workspaceAvailable: workspaceAvailable,
            workspaceLabel: workspacePathLabel(record.workspacePath),
            onTogglePinned: { togglePinned(record) },
            onExport: { export(record, format: $0) },
            onExportTaskBundle: { exportTaskBundleFile(for: record) }
        )
    }

    private func sourceTint(_ source: SessionSource) -> Color {
        switch source {
        case .app: Theme.accent
        case .claude: Theme.warning
        case .codex: Theme.info
        case .cursor: Theme.accentBright
        case .bundle: Theme.success
        }
    }

    // MARK: Import

    /// Imports a portable task only after three explicit user choices: the
    /// bundle file, its passphrase, and the destination workspace. Decryption
    /// happens off the main actor because PBKDF2 is intentionally expensive.
    private func runTaskBundleImport() {
        guard !isImportingBundle else { return }
        guard !sessions.isRunning else {
            showTaskBundleError("Stop the active task before importing another task.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Task Bundle"
        panel.message = "Choose a Beet Code task bundle to decrypt and rebind."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "beetask") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = TaskBundlePassphrasePrompt.ask(forExport: false) else { return }
        guard let data = try? Data(contentsOf: url) else {
            showTaskBundleError("The selected bundle could not be read.")
            return
        }

        isImportingBundle = true
        importStatus = "Decrypting task bundle…"
        Task.detached(priority: .userInitiated) {
            do {
                let bundle = try TaskBundleCodec.decode(data, passphrase: passphrase)
                await MainActor.run {
                    isImportingBundle = false
                    importStatus = nil
                    chooseWorkspaceForTaskBundle(bundle)
                }
            } catch {
                await MainActor.run {
                    isImportingBundle = false
                    importStatus = nil
                    showTaskBundleError(error.localizedDescription)
                }
            }
        }
    }

    /// A decrypted bundle never supplies its own destination. The selected
    /// folder is the only source of the new session's workspace binding.
    private func chooseWorkspaceForTaskBundle(_ bundle: TaskBundle) {
        let panel = NSOpenPanel()
        panel.title = "Choose Workspace for Imported Task"
        panel.message = bundle.workspaceHint.isEmpty
            ? "Choose the project folder where this task should continue."
            : "Rebind “\(bundle.workspaceHint)” to a project folder on this Mac."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let workspace = panel.url else { return }

        do {
            let record = try TaskBundleCodec.reboundSession(bundle, workspace: workspace)
            if case .failure(let error) = SessionStore.shared.save(record) {
                throw error
            }
            guard sessions.restore(record) else {
                SessionStore.shared.delete(record)
                throw TaskBundleError.workspaceRequired
            }
            selectedSessionID = record.id
            sidebarTab = .imported
            sourceFilter = .bundle
            importSummary = "Imported “\(record.title)” into \(workspace.lastPathComponent)."
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = workspace.standardizedFileURL.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: workspace)
            AppPreferencesStore.shared.save(preferences)
            Task { await reloadSessions() }
        } catch {
            showTaskBundleError(error.localizedDescription)
        }
    }

    private func showTaskBundleError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Task bundle import failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runImport() {
        guard !isImporting else { return }
        isImporting = true
        importSummary = nil
        importSummaryIsWarning = false
        importStatus = "Scanning Claude, Codex and Cursor histories…"
        DiagnosticsCenter.shared.record(.import, "History import started")
        Task.detached(priority: .utility) {
            let report = ExternalHistoryImporter.importAll { progress in
                Task { @MainActor in
                    importStatus = Self.progressLabel(progress)
                }
            }
            await MainActor.run {
                isImporting = false
                importStatus = nil
                let details = [
                    "\(report.imported) imported",
                    "\(report.upToDate) up to date",
                    "\(report.skipped) skipped",
                    report.failed > 0 ? "\(report.failed) failed to save" : nil
                ].compactMap { $0 }.joined(separator: " · ")
                DiagnosticsCenter.shared.record(
                    .import,
                    report.failed > 0 ? "History import completed with save failures" : "History import finished",
                    detail: report.lastSaveError.map { "\(details) · Last error: \($0)" } ?? details,
                    level: report.failed > 0 || (report.imported == 0 && report.upToDate == 0 && report.skipped == 0) ? .warning : .info)
                if report.imported == 0 && report.upToDate == 0 && report.skipped == 0 && report.failed == 0 {
                    importSummary = "No Claude, Codex or Cursor histories found on this Mac."
                } else if report.failed > 0 {
                    importSummaryIsWarning = true
                    importSummary = report.lastSaveError.map {
                        "\(details). Last save error: \($0)"
                    } ?? details
                } else {
                    var parts: [String] = []
                    if report.imported > 0 { parts.append("\(report.imported) imported") }
                    if report.upToDate > 0 { parts.append("\(report.upToDate) up to date") }
                    importSummary = parts.joined(separator: " · ")
                }
                Task { await reloadSessions() }
            }
        }
    }

    /// One-line status for the import's live parser feedback.
    private static func progressLabel(_ progress: ImportProgress) -> String {
        switch progress.phase {
        case .scanning:
            return "Scanning \(progress.source.label) history…"
        case .parsing:
            let detail = progress.detail.isEmpty ? "" : " · \(progress.detail)"
            return "Parsing \(progress.source.label) \(progress.completed + 1)/\(max(progress.total, 1))\(detail)"
        case .saving:
            return "Saving imported sessions \(progress.completed + 1)/\(max(progress.total, 1))…"
        }
    }

    @State private var lastSessionReload = Date.distantPast
    @State private var needsKeychainUnlock = false

    private func reloadSessions() async {
        // More than the visible ten: the Imported tab browses the same cache.
        let loaded = await Task.detached(priority: .utility) {
            Array(SessionStore.shared.loadAll().prefix(400))
        }.value
        needsKeychainUnlock = SessionCrypto.needsInteractiveUnlock
        pinnedSessionIDs = Set(AppPreferencesStore.shared.current.pinnedSessionIDs)
        recentSessions = loaded
        // Keep the highlight honest: the controller owns the active session;
        // a restore (or a run) elsewhere should show up here too.
        if let active = sessions.activeSessionID, selectedSessionID != active,
           recentSessions.contains(where: { $0.id == active }) {
            selectedSessionID = active
        }
    }

    /// Restore the picked session. Reports failure instead of no-op'ing so a
    /// click always has a visible outcome.
    private func selectSession(_ id: UUID?) {
        sessionRestoreError = nil
        guard let id else { return }
        // Snap-back after a failed restore re-fires selection with the
        // already-active session — don't rebuild its transcript twice.
        guard id != sessions.activeSessionID else { return }
        guard let record = recentSessions.first(where: { $0.id == id }) else { return }
        guard SessionStore.shared.validateWorkspaceBinding(record) else {
            sessionRestoreError = "Project folder no longer exists: \(record.workspacePath)"
            selectedSessionID = sessions.activeSessionID
            return
        }
        if sessions.restore(record) {
            // Persist so a relaunch lands back on this session too.
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = record.workspacePath
            AppPreferencesStore.shared.save(preferences)
            // A stale load error from the previous workspace is not this one's.
            if case .failed = appState.enginePhase {
                appState.enginePhase = .idle
            }
        } else {
            sessionRestoreError = "Could not restore \"\(record.title)\"."
            selectedSessionID = sessions.activeSessionID
        }
    }

    // MARK: Export

    /// Rail button: export the chat currently on screen. The active session
    /// is persisted after every run, so the store always has the latest copy.
    private func exportCurrentChat() {
        let id = sessions.activeSessionID ?? SessionStore.shared.currentSessionID
        guard let id, let record = SessionStore.shared.load(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Run a task first — the conversation is exported once it has been saved."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        export(record, format: .markdown)
    }

    /// Save panel → write the rendered document. A failed write surfaces as
    /// an alert instead of a silent no-op.
    private func export(_ record: SessionRecord, format: SessionExporter.Format) {
        let panel = NSSavePanel()
        panel.title = "Export Chat"
        panel.prompt = "Export"
        panel.nameFieldStringValue = SessionExporter.suggestedName(for: record, format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .markdown:
                try SessionExporter.markdown(for: record).write(to: url, atomically: true, encoding: .utf8)
            case .json:
                guard let data = SessionExporter.json(for: record) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "The agent works inside this folder and cannot escape it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            // Transactional switch: stop the run, clear state, restore the
            // new workspace's last session — never leave a stale checkpoint
            // pointing at the old project.
            Task {
                await sessions.switchWorkspace(to: url)
                // A load error from the previous workspace is stale here.
                if case .failed = appState.enginePhase {
                    appState.enginePhase = .idle
                }
                var preferences = AppPreferencesStore.shared.current
                preferences.lastWorkspacePath = url.path
                preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: url)
                AppPreferencesStore.shared.save(preferences)
            }
        }
    }
}

/// A session-list leaf with narrow display inputs, so updates to the sidebar
/// header and other session groups do not re-evaluate every row's content.
struct SessionHistoryRow: View {
    let record: SessionRecord
    let subtitle: String?
    let selected: Bool
    let pinned: Bool
    let sourceTint: Color
    let statusTitle: String?
    let statusIcon: String
    let statusColor: Color
    let workspaceAvailable: Bool
    let workspaceLabel: String
    let onTogglePinned: () -> Void
    let onExport: (SessionExporter.Format) -> Void
    let onExportTaskBundle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.source.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sourceTint)
                .frame(width: 24, height: 24)
                .background(Theme.wash(sourceTint), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(SessionTitle.display(for: record))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(record.source == .app ? Theme.textSecondary : sourceTint)
                            .padding(.horizontal, record.source == .app ? 0 : 5)
                            .frame(minHeight: record.source == .app ? nil : 17)
                            .background(record.source == .app ? Color.clear : Theme.wash(sourceTint), in: Capsule())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("\(record.messages.count) messages")
                        .monospacedDigit()
                    Text("·")
                    Text(SessionTitle.compactAge(record.updatedAt))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Pinned")
                }
                if let statusTitle {
                    HStack(spacing: 3) {
                        Image(systemName: statusIcon)
                            .font(.caption2.weight(.bold))
                        Text(statusTitle)
                            .lineLimit(1)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(statusTitle)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.wash(Theme.accent) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(selected ? Theme.accent : Color.clear)
                .frame(width: 3, height: 25)
        }
        .tag(record.id)
        .contextMenu {
            Button(pinned ? "Unpin task" : "Pin task", action: onTogglePinned)
            Divider()
            Button("Export as Markdown…") { onExport(.markdown) }
            Button("Export as JSON…") { onExport(.json) }
            Button("Export task bundle…", action: onExportTaskBundle)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .disabled(!workspaceAvailable)
        .help(workspaceAvailable ? "Restore this session" : "Project folder missing: \(record.workspacePath)")
        .accessibilityValue(
            "\(pinned ? "Pinned. " : "")\(statusTitle ?? "Completed"). Workspace: \(workspaceLabel)")
    }
}

/// Sidebar identity, primary actions, history controls, and the compact queue
/// lane. It receives only the values it renders plus closures for mutations,
/// keeping the session list isolated from header-only state changes.
struct SidebarHeaderView: View {
    let workspaceURL: URL?
    let sidebarTab: SidebarHistoryTab
    let importedCount: Int
    @Binding var historySearch: String
    let queuedTasks: [QueuedAgentTask]
    let isImporting: Bool
    let isImportingBundle: Bool
    let showsCloseButton: Bool
    let onChooseWorkspace: () -> Void
    let onImport: () -> Void
    let onImportTaskBundle: () -> Void
    let onRefresh: () -> Void
    let onNewSession: () -> Void
    let onSelectTab: (SidebarHistoryTab) -> Void
    let onRunNext: () -> Void
    let onRemoveQueuedTask: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            primaryActions
            historyModeBar
            searchField
            if !queuedTasks.isEmpty {
                queueSummary
            }
        }
        .padding(.horizontal, showsCloseButton ? 18 : 14)
        .padding(.top, showsCloseButton ? 14 : 16)
        .padding(.bottom, 14)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var identityRow: some View {
        HStack(spacing: 9) {
            workspaceMark
            VStack(alignment: .leading, spacing: 2) {
                Text("BEET CODE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textTertiary)
                Text(workspaceURL?.lastPathComponent ?? "Choose a workspace")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(workspaceURL == nil ? "Open a folder to begin" : "Current workspace")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onChooseWorkspace) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(LFIconButtonStyle(size: 26))
            .lfHoverLift()
            .help("Switch workspace")
            .accessibilityLabel("Switch workspace")

            if showsCloseButton {
                PanelCloseButton(action: onClose)
            }
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 7) {
            if sidebarTab == .imported {
                Button(action: onImport) {
                    Label(isImporting ? "Scanning…" : "Import chats", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .disabled(isImporting)
                .help("Import or refresh chats from Claude, Codex and Cursor")
            } else if workspaceURL == nil {
                Button(action: onChooseWorkspace) {
                    Label("Open workspace…", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .help("Choose a project folder")
            } else {
                Button(action: onNewSession) {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .help("Start a new chat in this workspace")
            }

            Menu {
                Button("Open workspace…", action: onChooseWorkspace)
                Divider()
                Button("Import chats…", action: onImport)
                    .disabled(isImporting)
                Button("Import task bundle…", action: onImportTaskBundle)
                    .disabled(isImportingBundle || isImporting)
                Button("Refresh chat list", action: onRefresh)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceInset, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .lfHoverLift()
            .help("More chat actions")
            .accessibilityLabel("More chat actions")
        }
    }

    private var workspaceMark: some View {
        Group {
            if let workspaceURL, let icon = AppIconLookup.workspace(workspaceURL.path) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: workspaceURL == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 30, height: 30)
        .background(Theme.washStrong(Theme.accent), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.washBorder(Theme.accent), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var historyModeBar: some View {
        HStack(spacing: 4) {
            historyModeButton(.sessions, title: "My chats", icon: "bubble.left.and.bubble.right")
            historyModeButton(.imported, title: "Other tools", icon: "arrow.down.doc", count: importedCount)
        }
        .padding(3)
        .background(Theme.surfaceInset.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 1))
    }

    private func historyModeButton(
        _ mode: SidebarHistoryTab,
        title: String,
        icon: String,
        count: Int? = nil
    ) -> some View {
        let active = sidebarTab == mode
        return Button {
            onSelectTab(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                if let count, count > 0 {
                    Text("\(min(count, 99))")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
                }
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 27)
            .background(active ? Theme.surface : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(
                active ? Theme.hairline : Color.clear,
                lineWidth: 1))
            .shadow(color: active ? Theme.cardShadow.opacity(0.45) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: active)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search all history", text: $historySearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !historySearch.isEmpty {
                Button { historySearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Theme.surfaceInset.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search chat history")
    }

    private var queueSummary: some View {
        let first = queuedTasks[0]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.info)
                Text(queuedTasks.count == 1 ? "1 task in queue" : "\(queuedTasks.count) tasks in queue")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                Button("Run next", action: onRunNext)
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .help("Start the next queued task when a model is ready")
            }

            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(queueStateColor(first.state))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(first.message)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(first.phase ?? first.state.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(queueStateColor(first.state))
                }
                Spacer(minLength: 0)
            }

            if queuedTasks.count > 1 {
                Menu {
                    ForEach(queuedTasks.prefix(5)) { task in
                        Button("Remove \(queueTaskMenuTitle(task))") {
                            onRemoveQueuedTask(task.id)
                        }
                    }
                } label: {
                    Text("Manage queued tasks…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Theme.wash(Theme.info), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.washBorder(Theme.info), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(queuedTasks.count) queued tasks")
    }

    private func queueTaskMenuTitle(_ task: QueuedAgentTask) -> String {
        let text = task.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = text.count > 32 ? String(text.prefix(32)) + "…" : text
        return "“\(short)”"
    }

    private func queueStateColor(_ state: QueuedTaskState) -> Color {
        switch state {
        case .awaitingApproval, .awaitingQuestion, .awaitingPlan:
            Theme.warning
        case .running:
            Theme.accent
        case .paused, .stopped:
            Theme.textTertiary
        case .queued:
            Theme.info
        case .completed:
            Theme.success
        case .failed:
            Theme.danger
        }
    }
}

struct ActiveModelRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch appState.enginePhase {
            case .idle:
                Label("No model loaded", systemImage: "cpu")
                    .foregroundStyle(Theme.textSecondary)
            case .loading(let name):
                Label("Loading \(name)…", systemImage: "hourglass")
                    .foregroundStyle(Theme.warning)
            case .ready(let name):
                Label(name, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                if let tps = appState.lastEngineStats.tokensPerSecond {
                    Text(String(format: "%.1f tokens/s", tps))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let reason):
                Label("Load failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                // Stale errors must not persist: dismiss returns to idle so a
                // fixed/downloaded model can be loaded without relaunching.
                Button("Dismiss") {
                    appState.enginePhase = .idle
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
