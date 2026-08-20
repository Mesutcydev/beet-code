import Combine
import Foundation
import SwiftUI

/// The single door between the UI and every service. Views never touch MLX,
/// the shell, or the file system directly — everything routes through here.
@MainActor
final class AppState: ObservableObject {

    enum EnginePhase: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
    }

    let settings = SettingsStore.shared
    let tokenStore = HFTokenStore.shared
    let modelStore = ModelStore.shared
    let thermal = ThermalMonitor()
    let engine: EngineRouter
    let preferences = AppPreferencesStore.shared

    /// Downloads run through here — the UI never touches the network layer.
    private(set) var downloadManager: ModelDownloadManager!

    /// Agent sessions — the UI drives the agent exclusively through this.
    let sessions: AgentSessionController

    @Published var activeModelID: String?
    /// The context window the resident engine actually runs with. GGUF loads
    /// fit the server ctx to the RAM budget, which can be smaller than the
    /// catalog window — compaction and the composer gauge must use this, or
    /// llama-server hard-errors (HTTP 400) mid-session. nil → catalog value.
    @Published var effectiveContextWindow: Int?
    /// True while the simulator side panel is docked — the window must be
    /// allowed to grow so sidebar + chat + simulator never clip each other.
    @Published var isSimulatorPanelOpen = false
    @Published var enginePhase: EnginePhase = .idle
    @Published var currentFootprint: UInt64 = 0
    @Published var availableBudget: UInt64 = 0
    @Published var lastEngineStats = EngineStats()

    private var pressureCoordinator: MemoryPressureCoordinator?
    private var statsTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Local OpenAI-compatible API server (loopback-only). Lazily created when
    /// the user enables it; nil while disabled.
    private var apiServer: LocalAPIServer?
    @Published var apiServerRunning = false
    @Published var apiServerError: String?
    @Published private(set) var apiServerToken: String?
    private var apiServerSyncGeneration = 0

    init(
        engine: EngineRouter = EngineRouter(pool: EnginePool()),
        hub hubOverride: (any HubServing)? = nil
    ) {
        // LocalForge → BeetCode rename migration: copies legacy Keychain
        // items (session key, BYOK keys, HF token) to the new services and
        // moves Application Support/LocalForge → BeetCode. Idempotent,
        // no-op under tests, and must run BEFORE any store is touched.
        LegacyMigration.runOnce()

        self.engine = engine
        // The vision sidecar serializes its Metal work through the same gate
        // as every resident LLM engine (one command buffer per process).
        if let gate = engine.enginePool?.sharedGate {
            VisionEngine.shared.configure(gate: gate)
        }
        self.downloadManager = ModelDownloadManager(
            tokenProvider: { HFTokenStore.currentToken() },
            hub: hubOverride)

        sessions = AgentSessionController(
            engine: engine,
            settings: SettingsStore.shared,
            thermal: thermal)
        sessions.activeModelIDHandler = { [weak self] in self?.activeModelID ?? "" }
        // The loop compacts against the engine's REAL launched window (GGUF
        // fits ctx to RAM), falling back to the catalog window for engines
        // that size context themselves.
        sessions.contextWindowHandler = { [weak self] in
            self?.effectiveContextWindow ?? self?.activeModel?.contextWindow
        }
        // `/model <id>` slash command: resolve against the catalog and
        // activate (load) the model, exactly like the Model Manager does.
        sessions.modelSwitchHandler = { [weak self] modelID in
            guard let self else { return }
            guard let catalog = ModelCatalog.model(id: modelID) else {
                self.enginePhase = .failed("Unknown model '\(modelID)' — check the Model Manager for ids.")
                return
            }
            Task { await self.activate(model: catalog) }
        }

        // Download completion is handled HERE — never in a UI row — so
        // registration is idempotent even when the Model Manager sheet is
        // closed.
        downloadManager.onCompletion = { [weak self] modelID in
            self?.finalizeDownload(modelID: modelID)
        }

        // Forward child-object changes so views observing AppState re-render
        // when downloads or the installed-model registry change.
        downloadManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The local API server follows its Settings toggle: enabling starts it
        // on the configured loopback port, disabling stops it. Port changes
        // while running restart it on the new port. SettingsStore publishes via
        // objectWillChange, so re-evaluate both values on any change.
        settings.objectWillChange
            .map { [settings] in (settings.apiServerEnabled, settings.apiServerPort) }
            .removeDuplicates(by: ==)
            .sink { [weak self] _ in
                self?.syncAPIServer()
            }
            .store(in: &cancellables)

        startPressureMonitoring()
        startStatsRefresh()
        restoreLaunchState()
        // Honor a persisted "server enabled" across launches.
        syncAPIServer()
    }

    // MARK: Launch restore (Phase 3.1)

    /// Restores workspace, session, and interrupted downloads after
    /// validating each piece. Failed restores fall back safely and never
    /// delete stored state.
    private func restoreLaunchState() {
        let preferences = preferences.current

        // Workspace: must still exist and be a directory.
        if let workspace = self.preferences.validatedWorkspaceURL() {
            Task { await self.sessions.switchWorkspace(to: workspace) }
            Log.app.info("Restored workspace \(workspace.path, privacy: .public)")
        }

        // Session: only when its workspace binding is still valid.
        if let sessionID = preferences.lastSessionID,
           let record = SessionStore.shared.load(id: sessionID),
           SessionStore.shared.validateWorkspaceBinding(record) {
            _ = sessions.restore(record)
            Log.app.info("Restored session \(record.title, privacy: .public)")
        }

        // Model: reload the last-used local model so the composer is ready
        // right after relaunch. lastModelID was always persisted but never
        // restored — after a crash or ⌘Q the user came back to a greyed-out
        // Send button ("Choose a model to run") despite having used one
        // minutes earlier. activate() runs the full guard chain (installed,
        // complete, chat-role, MemoryAdvisor admission) and no-ops cleanly
        // when any of it fails. Never under the test host: an auto-load
        // would page real weights mid-suite.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let modelID = preferences.lastModelID,
           let catalog = ModelCatalog.model(id: modelID) {
            Task { await self.activate(model: catalog) }
            Log.app.info("Auto-reloading last model \(modelID, privacy: .public)")
        }

        // Downloads: manifest scan already populated paused states; resume
        // only when the user opted in. Never under a test host: the app's
        // real Application Support is live there, and an auto-resumed
        // download would hit the network mid-suite and starve fixture runs.
        if preferences.autoResumeDownloads,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            for modelID in downloadManager.resumableModelIDs {
                guard let model = ModelCatalog.model(id: modelID) else { continue }
                startDownload(of: model)
                Log.app.info("Auto-resuming download \(modelID, privacy: .public)")
            }
        }
    }

    // MARK: System wiring

    private func startPressureMonitoring() {
        let coordinator = MemoryPressureCoordinator(
            onWarning: { [engine] in
                await engine.clearCaches()
                // ForgeCache pressure response: release disposable hot caches
                // first; durable task capsules and disk indexes survive.
                await ToolResultCache.shared.evictAll()
                RepoSummaryCache.shared.clearMemory()
            },
            onCritical: { [weak self, engine] in
                guard MemoryAdvisor.shouldDumpOnCriticalPressure else { return }
                // Cancel generation BEFORE dumping: a token loop must never
                // race the resident model leaving memory.
                await engine.cancelGeneration()
                await self?.sessions.stopAndWait()
                // The vision sidecar is the cheapest thing to drop first —
                // it holds no conversation state and reloads on demand.
                _ = await VisionEngine.shared.dumpIfResident()
                let dumped = await engine.dumpIfResident()
                if dumped {
                    MemoryAdvisor.notePressureDump()
                    // Emergency dump: the loaded model is gone — clear the
                    // UI state so chat is disabled until a model is loaded
                    // again.
                    await MainActor.run {
                        guard let self else { return }
                        self.sessions.stop()
                        self.activeModelID = nil
                        self.enginePhase = .idle
                        self.clearPersistedModel()
                    }
                }
            })
        coordinator.start()
        pressureCoordinator = coordinator
    }

    private func startStatsRefresh() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.currentFootprint = MemoryAdvisor.processFootprint
                self.availableBudget = MemoryAdvisor.availableBudget
                self.lastEngineStats = await self.engine.stats
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // Thermal changes are forwarded directly to the engine, without
        // waiting for the stats poll: critical heat cancels generation and
        // stops the agent.
        thermalTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.thermal.$effectiveState.values {
                if state == .critical {
                    await self.engine.cancelGeneration()
                    self.sessions.stop()
                }
            }
        }
    }

    // MARK: Model lifecycle (Phase 3.4)

    func budget(for model: CatalogModel) -> MemoryAdvisor.Budget {
        MemoryAdvisor.budget(diskBytes: model.diskBytes)
    }

    var activeModel: CatalogModel? {
        activeModelID.flatMap { ModelCatalog.model(id: $0) }
    }

    func activate(model: CatalogModel) async {
        clearStaleLoadError()
        // Reentrancy guard: two rapid Load clicks (or a click while a load is
        // paging in) must not race engine swaps — the second tap is ignored.
        if case .loading = enginePhase { return }
        // Vision sidecars are never loadable as the chat engine — they run
        // automatically when an image needs describing.
        guard model.role == .chat else {
            enginePhase = .failed("\(model.displayName) is a vision sidecar — it runs automatically for image attachments. Load a chat model instead.")
            return
        }
        guard let installed = modelStore.installedModel(id: model.id) else {
            enginePhase = .failed("\(model.displayName) is not downloaded yet.")
            return
        }
        // An interrupted/corrupt download can leave a directory without its
        // weights; surface that as a re-download prompt, not an engine error.
        guard modelStore.hasConfiguration(installed) else {
            enginePhase = .failed("\(model.displayName) is incomplete (missing weight files). Remove it and download again.")
            return
        }
        // An active agent must fully stop before its engine is swapped:
        // cancellation is awaited, so generation can never outlive the model.
        await sessions.stopAndWait()
        // Multi-resident pool: the previously active model STAYS RESIDENT
        // (warm KV cache) — the pool evicts LRU idle residents only when the
        // memory budget or the residency cap requires it. Single-resident
        // routers (test doubles) keep the old unload-first behavior.
        if engine.enginePool == nil, activeModelID != nil, activeModelID != model.id {
            await engine.unload()
            activeModelID = nil
        }
        let directory = modelStore.directory(for: installed)
        enginePhase = .loading(model.displayName)
        do {
            // The format is detected from what's actually on disk (a GGUF
            // download has no config.json), so user-imported models route
            // correctly too.
            let format = modelStore.detectedFormat(installed)
            try await engine.load(directory: directory, modelID: model.id, diskBytes: installed.sizeBytes, format: format, contextSize: model.contextWindow)
            activeModelID = model.id
            // The engine's REAL window (GGUF fits ctx to RAM) wins over the
            // catalog number; the agent loop compacts against this.
            effectiveContextWindow = await engine.effectiveContextWindow ?? model.contextWindow
            enginePhase = .ready(model.displayName)
            // Persist the selection only after a successful load.
            persistActiveModel(model.id)
        } catch {
            enginePhase = .failed(error.localizedDescription)
            activeModelID = nil
            effectiveContextWindow = nil
            clearPersistedModel()
        }
    }


    // MARK: BYOK remote engine (v0.3)

    /// Switches the engine to a BYOK provider. Requires the provider's API
    /// key to be present; returns false otherwise. The resident local model is
    /// explicitly unloaded first so RAM/Metal are freed while remote is active.
    @discardableResult
    func activateRemote(endpoint: RemoteEndpoint) async -> Bool {
        clearStaleLoadError()
        await sessions.stopAndWait()
        if activeModelID != nil || engine.source != .localMLX {
            await engine.unload()
            activeModelID = nil
            effectiveContextWindow = nil
            // Switching to BYOK is a deliberate leave: don't auto-reload the
            // local model on the next launch.
            clearPersistedModel()
        }
        guard engine.useRemote(endpoint) else {
            enginePhase = .failed("No API key configured for \(endpoint.provider.displayName).")
            return false
        }
        enginePhase = .ready("\(endpoint.provider.displayName) · \(endpoint.model)")
        return true
    }

    /// Switches back to the local MLX engine (a local model must be loaded
    /// for generation).
    func deactivateRemote() {
        Task { [weak self] in
            await self?.sessions.stopAndWait()
            self?.engine.useLocal()
            self?.activeModelID = nil
            self?.enginePhase = .idle
        }
    }

    var isRemoteActive: Bool {
        if case .remote = engine.source { return true }
        return false
    }
    func deactivate() async {
        clearStaleLoadError()
        await sessions.stopAndWait()
        await engine.unload()
        activeModelID = nil
        effectiveContextWindow = nil
        enginePhase = .idle
        clearPersistedModel()
    }

    /// A "Load failed" error belongs to ONE attempt: once the user moves on —
    /// switches workspace, changes models, goes remote — the stale banner is
    /// cleared so it never outlives the context that produced it (F5).
    private func clearStaleLoadError() {
        if case .failed = enginePhase {
            enginePhase = .idle
        }
    }

    // MARK: Local API server (v0.3)

    /// Reconciles the running server with the Settings toggle + port. Called
    /// whenever either changes; idempotent otherwise.
    private func syncAPIServer() {
        apiServerSyncGeneration &+= 1
        let generation = apiServerSyncGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.reconcileAPIServer(generation: generation)
        }
    }

    private func reconcileAPIServer(generation: Int) async {
        guard generation == apiServerSyncGeneration else { return }
        let enabled = settings.apiServerEnabled
        let port = settings.apiServerPort
        if enabled {
            await startAPIServer(port: port, generation: generation)
        } else {
            await stopAPIServer()
        }
    }

    /// Starts the loopback server. Restarted if the port differs from the
    /// currently bound port.
    private func startAPIServer(port: Int, generation: Int) async {
        if let existing = apiServer, await existing.isRunning {
            if await existing.actualPort == port { return }  // already right
            await existing.stop()
        }
        guard generation == apiServerSyncGeneration,
              settings.apiServerEnabled,
              settings.apiServerPort == port
        else { return }
        let server = apiServer ?? LocalAPIServer(engine: engine)
        apiServer = server
        let token = apiServerToken ?? UUID().uuidString
        apiServerToken = token
        do {
            try await server.start(.init(
                port: port,
                bindIPv6: false,
                modelIDOverride: activeModelID,
                bearerToken: token))
            guard generation == apiServerSyncGeneration,
                  settings.apiServerEnabled,
                  settings.apiServerPort == port
            else {
                await server.stop()
                return
            }
            apiServerRunning = true
            apiServerError = nil
        } catch {
            apiServerRunning = false
            apiServerError = error.localizedDescription
            enginePhase = .failed("Local API server: \(error.localizedDescription)")
        }
    }

    private func stopAPIServer() async {
        guard let server = apiServer else { return }
        await server.stop()
        apiServerRunning = false
        apiServerError = nil
        apiServerToken = nil
    }

    /// The URL a client should point at (shown in Settings).
    var apiServerBaseURL: String {
        "http://127.0.0.1:\(settings.apiServerPort)"
    }

    private func persistActiveModel(_ modelID: String) {
        var preferences = preferences.current
        preferences.lastModelID = modelID
        self.preferences.save(preferences)
    }

    private func clearPersistedModel() {
        var preferences = preferences.current
        if preferences.lastModelID != nil {
            preferences.lastModelID = nil
            self.preferences.save(preferences)
        }
    }

    // MARK: Download lifecycle (Phase 3.3)

    func destination(for model: CatalogModel) -> URL {
        // ModelStore's base directory (Application Support/BeetCode/Models/<id>)
        modelStore.modelsBaseURL.appendingPathComponent(model.id, isDirectory: true)
    }

    func startDownload(of model: CatalogModel) {
        guard modelStore.installedModel(id: model.id) == nil else { return }
        downloadManager.start(model: model, into: destination(for: model))
    }

    func pauseDownload(of model: CatalogModel) {
        downloadManager.pause(modelID: model.id)
    }

    func cancelDownload(of model: CatalogModel) {
        downloadManager.cancel(modelID: model.id, directory: destination(for: model))
    }

    /// Called by the download manager when a download reaches `.completed` —
    /// regardless of whether the Model Manager sheet is open. Sizes the
    /// directory off the main actor and registers it. Downloading never
    /// activates: loading is an explicit user decision, so a background
    /// download can never interrupt a running agent or switch engines.
    func finalizeDownload(modelID: String) {
        guard let model = ModelCatalog.model(id: modelID) else { return }
        let directory = destination(for: model)
        let catalog = model
        Task { [weak self] in
            guard let self else { return }
            let size = (try? await Task.detached {
                try ModelStore.sizeOfDirectory(directory)
            }.value) ?? catalog.diskBytes
            _ = self.modelStore.register(catalogModel: catalog, sizeBytes: size)
            Log.downloads.info("Registered \(modelID, privacy: .public) — ready to load")
        }
    }
}
