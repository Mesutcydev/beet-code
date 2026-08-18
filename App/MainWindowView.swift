import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @State private var showModelManager = false
    @State private var showSimulator = false
    @State private var showBrowser = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
                        .frame(minWidth: 360, idealWidth: 440, maxWidth: 560, maxHeight: .infinity)
                }

                // Agent-controlled browser: docked like the simulator so the
                // transcript stays visible while the agent drives the page.
                if showBrowser {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(sessions.workspaceURL?.lastPathComponent ?? "Beet Code")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showBrowser.toggle()
                } label: {
                    Label("Browser", systemImage: "safari")
                }
                .help("In-app browser the agent can control via browser_* tools")
                Button {
                    showSimulator = true
                    appState.isSimulatorPanelOpen = true
                } label: {
                    Label("Simulator", systemImage: "iphone")
                }
                .help("iOS Simulator panel — the agent can drive it via argent tools")
                Button {
                    showModelManager = true
                } label: {
                    Label("Models", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Download and manage local models")
            }
        }
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

    var body: some View {
        List(selection: $selectedSessionID) {
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.tertiary)
                }
            }
            Section("Active Model") {
                ActiveModelRow()
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
                let recent = recentSessions.prefix(10)
                if recent.isEmpty, !needsKeychainUnlock {
                    Text("Sessions appear here once you run a task.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recent)) { record in
                        // Tagged row + List(selection:) = real selectable rows.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .font(.callout)
                                .lineLimit(1)
                            // Distinguishes repeated titles: message count
                            // + relative time, monospaced digits so rows
                            // align and scan as a real list.
                            Text("\(record.messages.count) msgs · \(record.updatedAt, style: .relative)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .tag(record.id)
                        // Missing workspace: row stays visible (the session
                        // exists) but is marked and explained on click.
                        .disabled(!SessionStore.shared.validateWorkspaceBinding(record))
                        .help(SessionStore.shared.validateWorkspaceBinding(record)
                              ? "Restore this session"
                              : "Project folder missing: \(record.workspacePath)")
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
        .listStyle(.sidebar)
        // Selection IS the restore: picking a tagged row switches to that
        // session (and reports why when it can't — no more silent no-ops).
        .onChange(of: selectedSessionID) { _, newValue in
            selectSession(newValue)
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

    @State private var lastSessionReload = Date.distantPast
    @State private var needsKeychainUnlock = false

    private func reloadSessions() async {
        let loaded = await Task.detached(priority: .utility) {
            Array(SessionStore.shared.loadAll().prefix(10))
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