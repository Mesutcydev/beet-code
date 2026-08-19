import AppKit
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @State private var showModelManager = false
    @State private var showSimulator = false
    @State private var showBrowser = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showBrowser: $showBrowser, showSimulator: $showSimulator,
                        showDiagnostics: $showDiagnostics)
                // The 46-pt activity rail eats into the column — keep the
                // list's share wide enough for two-line session rows.
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ChatView(controller: sessions)
                    Divider()
                    StatusBarView()
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                // Docked side window: the simulator panel lives next to the
                // chat instead of a modal sheet, so the transcript stays
                // visible while the agent drives the device. Full height,
                // fixed-ish width — never centered or overflowing.
                if showSimulator {
                    Divider()
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                        .environmentObject(appState)
                        // Phone screens are ~9:19.5 — the column must be wide
                        // enough for the stream to read as a phone, not a sliver.
                        .frame(minWidth: 380, idealWidth: 480, maxWidth: 560, maxHeight: .infinity)
                }

                // Agent-controlled browser: docked like the simulator so the
                // transcript stays visible while the agent drives the page.
                if showBrowser {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680, maxHeight: .infinity)
                }

                // Diagnostics: docked like the other panels — breadcrumb
                // timeline + system snapshot, exportable for bug reports.
                if showDiagnostics {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 340, idealWidth: 420, maxWidth: 560, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(sessions.workspaceURL?.lastPathComponent ?? "Beet Code")
        // Engine transitions are breadcrumbs too — recorded from this single
        // observation point so AppState needs no diagnostics dependency.
        .onChange(of: appState.enginePhase) { _, phase in
            switch phase {
            case .idle:
                DiagnosticsCenter.shared.record(.engine, "Engine idle")
            case .loading(let name):
                DiagnosticsCenter.shared.record(.engine, "Loading \(name)…")
            case .ready(let name):
                DiagnosticsCenter.shared.record(.engine, "\(name) ready")
            case .failed(let reason):
                DiagnosticsCenter.shared.record(.engine, "Model load failed",
                                                detail: reason, level: .error)
            }
        }
        // Tint the system chrome too: without this the toolbar and sidebar
        // stay neutral gray while Beet mode plums every themed surface.
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // No toolbar buttons on purpose: every action lives in the sidebar's
        // activity rail — one home for navigation, panels and app windows.
        .sheet(isPresented: $showModelManager) {
            ModelManagerView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 480)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelManager)) { _ in
            showModelManager = true
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    /// Docked panel state lives in MainWindowView; the activity rail drives
    /// it through these bindings (one source of truth, no notifications).
    @Binding var showBrowser: Bool
    @Binding var showSimulator: Bool
    @Binding var showDiagnostics: Bool
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
    @State private var sidebarTab: HistoryTab = .sessions
    @State private var isImporting = false
    @State private var importSummary: String?
    /// Live parser feedback while an import runs (source + file + count).
    @State private var importStatus: String?
    @State private var hasAutoImported = false

    private enum HistoryTab {
        case sessions, imported
    }

    var body: some View {
        HStack(spacing: 0) {
            activityRail
            Divider().overlay(Theme.hairline)
            List(selection: $selectedSessionID) {
                if sidebarTab == .sessions {
                    ownSections
                } else {
                    importedSections
                }
            }
            .listStyle(.sidebar)
            // The sidebar List's system material ignores the Theme ramp —
            // hide it so Beet mode's plum bg shows here too.
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
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
                runImport()
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

    // MARK: Activity rail

    /// Slim icon-only rail on the sidebar's leading edge (VS Code style).
    /// One home for every button in the window, in a fixed order:
    /// navigation tabs → docked tool panels → (spacer) → app windows.
    /// The Imported icon carries a badge — a live spinner while an import
    /// runs, otherwise the imported-chat count.
    private var activityRail: some View {
        VStack(spacing: Spacing.xs) {
            // Compose: a fresh chat in the current workspace.
            railIcon(icon: "square.and.pencil",
                     help: "New chat") {
                sessions.newSession()
                selectedSessionID = nil
                sidebarTab = .sessions
            }
            railDivider()
            // Navigation: which history the panel shows.
            railIcon(icon: "bubble.left.and.bubble.right",
                     help: "Your sessions",
                     isActive: sidebarTab == .sessions) {
                sidebarTab = .sessions
            }
            railIcon(icon: "tray.and.arrow.down",
                     help: "Chats imported from Claude, Codex and Cursor",
                     isActive: sidebarTab == .imported, badge: true) {
                sidebarTab = .imported
            }
            railDivider()
            // Docked tool panels (the old top-right toolbar duplicates —
            // moved here so the rail is the only place buttons live).
            railIcon(icon: "safari",
                     help: "Browser panel — the agent can drive it via browser_* tools",
                     isActive: showBrowser) {
                showBrowser.toggle()
            }
            railIcon(icon: "iphone",
                     help: "Simulator panel — the agent can drive it via argent tools",
                     isActive: showSimulator) {
                showSimulator.toggle()
                appState.isSimulatorPanelOpen = showSimulator
            }
            railIcon(icon: "stethoscope",
                     help: "Diagnostics — breadcrumb timeline and system info",
                     isActive: showDiagnostics) {
                showDiagnostics.toggle()
            }
            Spacer()
            // Export the chat currently on screen (Markdown document).
            railIcon(icon: "square.and.arrow.up",
                     help: "Export current chat as Markdown") {
                exportCurrentChat()
            }
            // App windows, anchored to the bottom like macOS conventions.
            railIcon(icon: "square.and.arrow.down.on.square",
                     help: "Model Manager (⇧⌘M)") {
                NotificationCenter.default.post(name: .openModelManager, object: nil)
            }
            railIcon(icon: "gearshape", help: "Settings (⌘,)") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .padding(.vertical, Spacing.sm)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// One rail button: 32×32 icon, accent wash when active, optional
    /// top-trailing badge slot (used by the Imported tab).
    private func railIcon(icon: String, help: String, isActive: Bool = false,
                          badge: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    isActive ? Theme.wash(Theme.accent) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge { importedBadge }
                }
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func railDivider() -> some View {
        Divider()
            .overlay(Theme.hairline)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
    }

    /// Badge on the Imported rail icon: a live spinner while the import
    /// runs, then the number of imported chats (hidden when zero).
    @ViewBuilder
    private var importedBadge: some View {
        if isImporting {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
                .offset(x: 4, y: -4)
        } else {
            let count = recentSessions.filter { $0.source != .app }.count
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.accent, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
    }

    // MARK: Own sessions

    @ViewBuilder
    private var ownSections: some View {
        Section("Workspace") {
            Button {
                chooseWorkspace()
            } label: {
                Label(
                    sessions.workspaceURL?.lastPathComponent ?? "Open Project Folder…",
                    systemImage: sessions.workspaceURL == nil
                        ? "folder.badge.plus" : "folder.fill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Section("Repository") {
            if sessions.workspaceURL == nil {
                Text("Open a workspace to use git controls.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    Button("Status") { sessions.gitStatus() }
                        .controlSize(.small)
                    Button("Diff") { sessions.gitDiff() }
                        .controlSize(.small)
                    Button("Undo") { sessions.undoLastCheckpoint() }
                        .controlSize(.small)
                }
                if let output = sessions.gitOutput {
                    ScrollView {
                        Text(output)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                    .padding(6)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                Text("Undo restores the latest agent checkpoint — git index state is preserved.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        Section("Active Model") {
            ActiveModelRow()
        }
        // Imported chats that belong to THIS workspace — the visible half
        // of workspace history (the agent also gets a digest of these as
        // context on every run in this folder).
        if let workspace = sessions.workspaceURL {
            let related = recentSessions.filter {
                $0.source != .app && $0.workspacePath == workspace.path
            }
            if !related.isEmpty {
                Section("From Other Tools · \(related.count)") {
                    ForEach(related) { record in
                        sessionRow(record, subtitle: record.source.label)
                    }
                }
            }
        }
        Section("Recent Sessions") {
            // Keychain re-authorization (ad-hoc re-signed builds): one
            // visible, bounded unlock instead of a silent hang.
            if needsKeychainUnlock {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session history is locked.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Button("Unlock") {
                        if SessionCrypto.unlockInteractively() {
                            needsKeychainUnlock = false
                            Task { await reloadSessions() }
                        }
                    }
                    .controlSize(.small)
                }
            }
            let recent = recentSessions.filter { $0.source == .app }.prefix(10)
            if recent.isEmpty, !needsKeychainUnlock {
                Text("Sessions appear here once you run a task.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(recent)) { record in
                    sessionRow(record, subtitle: nil)
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

    // MARK: Imported history

    @ViewBuilder
    private var importedSections: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                Button(isImporting ? "Importing…" : "Import Chat History") {
                    runImport()
                }
                .disabled(isImporting)
                if isImporting {
                    ProgressView().controlSize(.small)
                }
            }
            // Live parser feedback: which tool's history is being read and
            // how far along it is — imports used to sit silent for minutes.
            if isImporting, let importStatus {
                Text(importStatus)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text("Reads Claude (~/.claude), Codex (~/.codex) and Cursor workspace histories. Everything stays on this Mac — imported sessions are encrypted exactly like your own.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
            if let importSummary {
                Text(importSummary)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Label("Import", systemImage: "square.and.arrow.down")
        }

        let imported = recentSessions.filter { $0.source != .app }
        if imported.isEmpty {
            Section {
                Text("Nothing imported yet — run the import above.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            // Source filter pills: narrow the list to chats from one tool
            // (Claude / Codex / Cursor) or show everything. Only sources
            // actually present get a pill.
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        sourcePill(source: nil, label: "All",
                                   icon: "tray.full", count: imported.count)
                        ForEach(sourcesPresent(in: imported), id: \.self) { source in
                            sourcePill(source: source, label: source.label,
                                       icon: source.systemImage,
                                       count: imported.filter { $0.source == source }.count)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            let filtered = sourceFilter == nil
                ? imported
                : imported.filter { $0.source == sourceFilter }
            if filtered.isEmpty {
                Section {
                    Text("No chats from \(sourceFilter?.label ?? "this tool").")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                // Project-based grouping with collapsible headers: a chat
                // belongs to the folder it was written in, whichever tool
                // wrote it. Groups sort by most recent activity; the row
                // badge still names the source tool.
                ForEach(projectGroups(filtered)) { group in
                    projectHeader(group)
                    if !collapsedProjects.contains(group.key) {
                        ForEach(group.records) { record in
                            sessionRow(record, subtitle: record.source.label)
                        }
                    }
                }
            }
        }
    }

    /// Which imported sources appear in the list, in a stable order.
    private func sourcesPresent(in records: [SessionRecord]) -> [SessionSource] {
        SessionSource.allCases.filter { source in
            source != .app && records.contains { $0.source == source }
        }
    }

    /// One source-filter pill: icon + label + count, accent-highlighted
    /// while active. `source == nil` is the "All" pill.
    private func sourcePill(source: SessionSource?, label: String,
                            icon: String, count: Int) -> some View {
        let isActive = sourceFilter == source
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                sourceFilter = source
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Theme.washStrong(Theme.accent) : Theme.surface,
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Theme.washBorder(Theme.accent) : Theme.hairline,
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

    /// A project group's header row: bold chevron, accent-filled folder
    /// tile, headline-sized name, big count pill — an oversized tappable
    /// card that can never be mistaken for a chat row.
    private func projectHeader(_ group: ProjectGroup) -> some View {
        let isCollapsed = collapsedProjects.contains(group.key)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isCollapsed {
                    collapsedProjects.remove(group.key)
                } else {
                    collapsedProjects.insert(group.key)
                }
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 14)
                Image(systemName: group.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(group.records.count)")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.washStrong(Theme.accent), in: Capsule())
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(Theme.surfaceInset,
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name), \(group.records.count) chats")
        .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
    }

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
            let sorted = group.sorted { $0.updatedAt > $1.updatedAt }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title)
                .font(.callout)
                .lineLimit(1)
            // Distinguishes repeated titles: message count + relative time,
            // monospaced digits so rows align and scan as a real list.
            Text("\(subtitle.map { $0 + " · " } ?? "")\(record.messages.count) msgs · \(record.updatedAt, style: .relative)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .tag(record.id)
        // Every row can be exported on its own — the rail button covers the
        // active chat, the context menu covers everything else.
        .contextMenu {
            Button("Export as Markdown…") { export(record, format: .markdown) }
            Button("Export as JSON…") { export(record, format: .json) }
        }
        // Missing workspace: row stays visible (the session exists) but is
        // marked and explained on click.
        .disabled(!SessionStore.shared.validateWorkspaceBinding(record))
        .help(SessionStore.shared.validateWorkspaceBinding(record)
              ? "Restore this session"
              : "Project folder missing: \(record.workspacePath)")
    }

    // MARK: Import

    private func runImport() {
        guard !isImporting else { return }
        isImporting = true
        importSummary = nil
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
                DiagnosticsCenter.shared.record(
                    .import, "History import finished",
                    detail: "\(report.imported) imported · \(report.upToDate) up to date · \(report.skipped) skipped",
                    level: report.imported == 0 && report.upToDate == 0 && report.skipped == 0 ? .warning : .info)
                if report.imported == 0 && report.upToDate == 0 && report.skipped == 0 {
                    importSummary = "No Claude, Codex or Cursor histories found on this Mac."
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
            Array(SessionStore.shared.loadAll().prefix(60))
        }.value
        needsKeychainUnlock = SessionCrypto.needsInteractiveUnlock
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

private struct ActiveModelRow: View {
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