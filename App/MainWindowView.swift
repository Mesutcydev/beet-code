import AppKit
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @State private var showModelManager = false
    @State private var showSimulator = false
    @State private var showBrowser = false
    @State private var showDiagnostics = false
    @State private var showRemoteAccess = false
    @State private var showCompactSidebar = false

    private var dockedPanelOpen: Bool {
        showSimulator || showBrowser || showDiagnostics
    }

    /// Chat keeps leftover space; mins drop when a docked panel is open so
    /// the three columns fit a 960-pt window instead of overflowing.
    private var chatMinWidth: CGFloat { dockedPanelOpen ? 300 : 380 }

    var body: some View {
        notificationView
    }

    private var configuredLayout: some View {
        responsiveLayout
            .navigationTitle(sessions.workspaceURL?.lastPathComponent ?? "Beet Code")
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
            .toolbarBackground(Theme.bg, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .background(Theme.bg)
    }

    private var presentationView: some View {
        configuredLayout
            .sheet(isPresented: $showModelManager) {
                ModelManagerView()
                    .environmentObject(appState)
                    .frame(minWidth: 640, minHeight: 480)
            }
            .sheet(isPresented: $showRemoteAccess) {
                RemoteAccessView()
                    .environmentObject(appState)
            }
    }

    private var notificationView: some View {
        presentationView
            .onReceive(NotificationCenter.default.publisher(for: .openModelManager)) { _ in
                showModelManager = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openRemoteAccess)) { _ in
                showRemoteAccess = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openBrowserPanel)) { _ in
                showBrowser = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleBrowserPanel)) { _ in
                showBrowser.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSimulatorPanel)) { _ in
                showSimulator.toggle()
                appState.isSimulatorPanelOpen = showSimulator
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleDiagnosticsPanel)) { _ in
                showDiagnostics.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitStatus)) { _ in
                sessions.gitStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitDiff)) { _ in
                sessions.gitDiff()
            }
            .onReceive(NotificationCenter.default.publisher(for: .undoCheckpoint)) { _ in
                sessions.undoLastCheckpoint()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportChatMarkdown)) { _ in
                exportCurrentChat(format: .markdown)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportChatJSON)) { _ in
                exportCurrentChat(format: .json)
            }
            .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
                sessions.newSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopAgent)) { _ in
                sessions.stop()
            }
    }

    /// Export the active conversation even when the sidebar is collapsed. The
    /// sidebar rows still offer the same actions for older chats; these
    /// notifications make the current chat reachable from the top bar too.
    private func exportCurrentChat(format: SessionExporter.Format) {
        let id = sessions.activeSessionID ?? SessionStore.shared.currentSessionID
        guard let id, let record = SessionStore.shared.load(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Run a task first — the conversation is exported once it has been saved."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Chat"
        panel.prompt = "Export"
        panel.nameFieldStringValue = SessionExporter.suggestedName(for: record, format: format)
        panel.allowedContentTypes = [format == .markdown ? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .markdown:
                try SessionExporter.markdown(for: record)
                    .write(to: url, atomically: true, encoding: .utf8)
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

    private var responsiveLayout: some View {
        GeometryReader { proxy in
            layout(for: proxy.size.width)
        }
    }

    private func layout(for width: CGFloat) -> AnyView {
        if width < 900 {
            return AnyView(portraitLayout)
        }
        return AnyView(wideLayout)
    }

    private var wideLayout: some View {
        NavigationSplitView {
            SidebarView(showBrowser: $showBrowser, showSimulator: $showSimulator,
                        showDiagnostics: $showDiagnostics,
                        showRemoteAccess: $showRemoteAccess)
                .navigationSplitViewColumnWidth(min: 240, ideal: 292, max: 380)
        } detail: {
            HStack(spacing: 0) {
                chatColumn
                    .frame(minWidth: chatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                if showSimulator {
                    Divider()
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                    .environmentObject(appState)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
                }
                if showBrowser {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                }
                if showDiagnostics {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            ChatView(controller: sessions)
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// Portrait windows use one readable column. Sidebar/history and tools
    /// become sheets instead of competing for horizontal space with the
    /// transcript and composer.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showCompactSidebar = true
                } label: {
                    Label("Chats", systemImage: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    sessions.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("New chat")
                Spacer()
                Text(sessions.workspaceURL?.lastPathComponent ?? "Beet Code")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            chatColumn
        }
        .background(Theme.bg)
        .sheet(isPresented: $showCompactSidebar) {
            SidebarView(showBrowser: $showBrowser, showSimulator: $showSimulator,
                        showDiagnostics: $showDiagnostics,
                        showRemoteAccess: $showRemoteAccess)
            .environmentObject(appState)
            .environmentObject(sessions)
            .frame(minWidth: 320, idealWidth: 360, minHeight: 500)
        }
        .sheet(isPresented: $showBrowser) {
            BrowserPanelView(onClose: { showBrowser = false })
                .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showSimulator) {
            SimulatorPanelView(onClose: {
                showSimulator = false
                appState.isSimulatorPanelOpen = false
            })
            .environmentObject(appState)
            .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsPanelView(onClose: { showDiagnostics = false })
                .frame(minWidth: 360, idealWidth: 520, minHeight: 420)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    /// Docked panel state lives in MainWindowView; the sidebar footer drives
    /// it through these bindings (one source of truth, no notifications).
    @Binding var showBrowser: Bool
    @Binding var showSimulator: Bool
    @Binding var showDiagnostics: Bool
    @Binding var showRemoteAccess: Bool
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
        VStack(spacing: 0) {
            sidebarHeader
            Divider().overlay(Theme.hairline)
            List(selection: $selectedSessionID) {
                historyListHeader
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

    // MARK: Sidebar header

    /// A single macOS-style navigation header: identity first, then the
    /// primary action, history switcher, and search. The list below is allowed
    /// to stay visually quiet because the header already answers “where am I?”.
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                workspaceMark
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEET CODE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Theme.textTertiary)
                    Text(sessions.workspaceURL?.lastPathComponent ?? "Choose a workspace")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button(action: chooseWorkspace) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Switch workspace")
                .accessibilityLabel("Switch workspace")
            }

            HStack(spacing: 7) {
                Button {
                    sessions.newSession()
                    selectedSessionID = nil
                    sidebarTab = .sessions
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .help("Start a new chat in this workspace")

                if sidebarTab == .imported {
                    Button(action: runImport) {
                        Image(systemName: isImporting ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isImporting)
                    .help("Scan Claude, Codex and Cursor history again")
                    .accessibilityLabel("Scan imported chats again")
                }

                Menu {
                    Button("Open workspace…", action: chooseWorkspace)
                    Divider()
                    Button("Import chats…", action: runImport)
                        .disabled(isImporting)
                    Button("Refresh chat list") { Task { await reloadSessions() } }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("More chat actions")
                .accessibilityLabel("More chat actions")
            }

            historyModeBar
            searchField
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.surface.opacity(0.38))
    }

    private var workspaceMark: some View {
        Group {
            if let workspace = sessions.workspaceURL,
               let icon = AppIconLookup.workspace(workspace.path) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: sessions.workspaceURL == nil ? "folder.badge.plus" : "folder.fill")
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
        HStack(spacing: 0) {
            historyModeButton(.sessions, title: "Chats", icon: "bubble.left.and.bubble.right")
            historyModeButton(.imported, title: "Imported", icon: "tray.and.arrow.down",
                              count: recentSessions.filter { $0.source != .app }.count)
        }
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func historyModeButton(_ mode: HistoryTab, title: String, icon: String,
                                   count: Int? = nil) -> some View {
        let active = sidebarTab == mode
        return Button {
            sidebarTab = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                if let count, count > 0 {
                    Text("\(min(count, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
                }
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField(sidebarTab == .sessions ? "Search chats" : "Search imported chats",
                      text: $historySearch)
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
        .accessibilityLabel(sidebarTab == .sessions ? "Search chats" : "Search imported chats")
    }

    /// A quiet library header makes the two history modes feel like distinct
    /// destinations. The old list began immediately with a project row, which
    /// made imported chats and local chats look like the same flat collection.
    @ViewBuilder
    private var historyListHeader: some View {
        if sidebarTab == .sessions {
            historyListHeader(
                eyebrow: "LOCAL LIBRARY",
                title: "Your chats",
                detail: "Saved in Beet Code",
                count: recentSessions.filter { $0.source == .app }.count,
                icon: "bubble.left.and.bubble.right.fill",
                tint: Theme.accent)
        } else {
            historyListHeader(
                eyebrow: "CHAT ARCHIVE",
                title: "Imported chats",
                detail: "Claude · Codex · Cursor",
                count: recentSessions.filter { $0.source != .app }.count,
                icon: "tray.and.arrow.down.fill",
                tint: Theme.info)
        }
    }

    private func historyListHeader(
        eyebrow: String,
        title: String,
        detail: String,
        count: Int,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(Theme.wash(tint), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textTertiary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 3, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) chats")
    }

    // MARK: Sidebar footer

    /// Tool destinations stay in the sidebar, but are named and grouped so
    /// they read as part of the navigation model rather than as unexplained
    /// floating glyphs in a second rail.
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 4) {
                footerTool("Browser", icon: "safari", isActive: showBrowser) {
                    showBrowser.toggle()
                }
                footerTool("Simulator", icon: "iphone", isActive: showSimulator) {
                    showSimulator.toggle()
                    appState.isSimulatorPanelOpen = showSimulator
                }
                footerTool("Diagnostics", icon: "stethoscope", isActive: showDiagnostics) {
                    showDiagnostics.toggle()
                }
                Menu {
                    Button("Remote sessions…") { showRemoteAccess = true }
                    Divider()
                    Button("Export current chat…") { exportCurrentChat() }
                    Button("Model manager…") {
                        NotificationCenter.default.post(name: .openModelManager, object: nil)
                    }
                    Button("Settings…") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                        Text("More")
                            .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isActive ? Theme.wash(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
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
        if isImporting, let importStatus {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(importStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 4)
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
                ForEach(importGroups(filtered)) { group in
                    collapsibleGroup(key: "import:\(group.source.rawValue)",
                                     icon: group.source.systemImage,
                                     name: group.source.label,
                                     records: group.records,
                                     workspacePath: "import:\(group.source.rawValue)",
                                     subtitle: { importRowSubtitle($0) })
                }
            }
        }
    }

    private func workspaceAction(_ title: String, icon: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(title)
    }

    private var importedEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Bring your other coding chats here")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Import Claude, Codex, or Cursor history. Everything stays on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                runImport()
            } label: {
                Label("Scan for chats", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.accent)
            .disabled(isImporting)
        }
        .padding(.vertical, 8)
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
                Text("SOURCES")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(imported.count) chats")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
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
        .padding(.vertical, 3)
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
                if source == nil {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
            }
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 25)
            .background(isActive ? Theme.surface : Theme.surfaceInset.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                    isActive ? Theme.hairline : Color.clear,
                    lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    private struct ImportGroup: Identifiable {
        let source: SessionSource
        let records: [SessionRecord]
        var id: String { source.rawValue }
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

    private func importGroups(_ records: [SessionRecord]) -> [ImportGroup] {
        SessionSource.allCases
            .filter { $0 != .app }
            .compactMap { source in
                let records = records
                    .filter { $0.source == source }
                    .sorted { $0.updatedAt > $1.updatedAt }
                guard !records.isEmpty else { return nil }
                return ImportGroup(source: source, records: records)
            }
            .sorted { lhs, rhs in
                (lhs.records.first?.updatedAt ?? .distantPast)
                    > (rhs.records.first?.updatedAt ?? .distantPast)
            }
    }

    private func importRowSubtitle(_ record: SessionRecord) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !record.workspacePath.isEmpty,
              record.workspacePath != home else {
            return "No project folder"
        }
        return URL(fileURLWithPath: record.workspacePath).lastPathComponent
    }

    /// One session row — tagged for List selection, marked and explained
    /// when its project folder is gone. `subtitle` prefixes the metadata
    /// line (used to badge the import source).
    private func sessionRow(_ record: SessionRecord, subtitle: String?) -> some View {
        let selected = selectedSessionID == record.id
        return HStack(spacing: 10) {
            Image(systemName: record.source.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(record.source == .app ? Theme.accent : Theme.info)
                .frame(width: 24, height: 24)
                .background(Theme.surfaceInset.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(SessionTitle.display(for: record))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text("\(record.messages.count) messages")
                        .monospacedDigit()
                    Text("·")
                    Text(SessionTitle.compactAge(record.updatedAt))
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
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
        // Every row can be exported on its own — the rail button covers the
        // active chat, the context menu covers everything else.
        .contextMenu {
            Button("Export as Markdown…") { export(record, format: .markdown) }
            Button("Export as JSON…") { export(record, format: .json) }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
