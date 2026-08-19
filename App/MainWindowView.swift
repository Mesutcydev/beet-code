import AppKit
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @State private var showModelManager = false
    @State private var showSimulator = false
    @State private var showBrowser = false
    @State private var showDiagnostics = false

    private var dockedPanelOpen: Bool {
        showSimulator || showBrowser || showDiagnostics
    }

    /// Chat keeps leftover space; mins drop when a docked panel is open so
    /// the three columns fit a 960-pt window instead of overflowing.
    private var chatMinWidth: CGFloat { dockedPanelOpen ? 300 : 380 }

    var body: some View {
        NavigationSplitView {
            SidebarView(showBrowser: $showBrowser, showSimulator: $showSimulator,
                        showDiagnostics: $showDiagnostics)
                // The 46-pt activity rail eats into the column — keep the
                // list's share wide enough for two-line session rows.
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ChatView(controller: sessions)
                    Divider()
                    StatusBarView()
                }
                .frame(minWidth: chatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if showSimulator {
                    Divider()
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                        .environmentObject(appState)
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
                        .layoutPriority(0)
                }

                if showBrowser {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                        .layoutPriority(0)
                }

                if showDiagnostics {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                        .layoutPriority(0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
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
        .background(Theme.bg)
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
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            sessions.newSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopAgent)) { _ in
            sessions.stop()
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
    @State private var historySearch = ""

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
        Section {
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your chats")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(sessions.workspaceURL?.lastPathComponent ?? "Open a project folder to start")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: chooseWorkspace) {
                    Image(systemName: sessions.workspaceURL == nil ? "folder.badge.plus" : "folder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(sessions.workspaceURL == nil ? "Open project folder" : "Switch project folder")
            }
            TextField("Search chats…", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
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

        if sessions.workspaceURL != nil {
            Section {
                HStack(spacing: 8) {
                    Button("Status") { sessions.gitStatus() }
                        .controlSize(.small)
                    Button("Diff") { sessions.gitDiff() }
                        .controlSize(.small)
                    Button("Undo") { sessions.undoLastCheckpoint() }
                        .controlSize(.small)
                    Spacer()
                }
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
                Text("Sessions appear here once you run a task.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            ForEach(projectGroups(own)) { group in
                collapsibleGroup(key: "own:" + group.key, icon: group.icon,
                                 name: group.name, records: group.records,
                                 workspacePath: group.key, subtitle: nil)
            }
        }

        if let workspace = sessions.workspaceURL {
            let related = recentSessions.filter {
                $0.source != .app && $0.workspacePath == workspace.path
            }.filter { matchesSearch($0) }
            if !related.isEmpty {
                collapsibleGroup(key: "related:" + workspace.path,
                                 icon: "tray.and.arrow.down",
                                 name: "From other tools",
                                 records: related,
                                 workspacePath: workspace.path,
                                 subtitle: { $0.source.label })
            }
        }
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

    // MARK: Imported history

    @ViewBuilder
    private var importedSections: some View {
        Section {
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported chats")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(importHeadline)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(action: runImport) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isImporting)
                .help("Scan Claude, Codex and Cursor histories on this Mac")
                .accessibilityLabel("Scan again")
            }
            if isImporting, let importStatus {
                Text(importStatus)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            TextField("Search chats, projects…", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }

        let imported = recentSessions.filter { $0.source != .app }
        if imported.isEmpty {
            Section {
                Text("Nothing imported yet — tap the refresh icon to scan this Mac.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        sourcePill(source: nil, label: "All",
                                   icon: "tray.full", count: imported.count)
                        ForEach(importSources, id: \.self) { source in
                            sourcePill(source: source, label: source.label,
                                       icon: source.systemImage,
                                       count: imported.filter { $0.source == source }.count)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            let filtered = visibleImported(imported)
            if filtered.isEmpty {
                Section {
                    Text(historySearch.isEmpty
                         ? "No chats from \(sourceFilter?.label ?? "this tool")."
                         : "No chats match “\(historySearch)”.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ForEach(projectGroups(filtered)) { group in
                    collapsibleGroup(key: group.key, icon: group.icon,
                                     name: group.name, records: group.records,
                                     workspacePath: group.key,
                                     subtitle: sourceFilter == nil ? { $0.source.label } : nil)
                }
            }
        }
    }

    private var importHeadline: String {
        if let importStatus, isImporting { return importStatus }
        if let importSummary { return importSummary }
        return "Claude, Codex and Cursor — stays on this Mac"
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

    private func expansionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(key) },
            set: { expanded in
                if expanded { collapsedProjects.remove(key) }
                else { collapsedProjects.insert(key) }
            })
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
    private var importSources: [SessionSource] { [.claude, .codex, .cursor] }

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
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
            }
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Theme.surface : Theme.surfaceInset,
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Theme.hairline : Color.clear,
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
            Text(SessionTitle.display(for: record))
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("·")
                        .foregroundStyle(Theme.textTertiary)
                }
                Text("\(record.messages.count)")
                    .monospacedDigit()
                Text("·")
                Text(SessionTitle.compactAge(record.updatedAt))
                    .monospacedDigit()
            }
            .font(.caption2)
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
            Array(SessionStore.shared.loadAll().prefix(400))
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