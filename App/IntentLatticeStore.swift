import Combine
import Foundation
import Observation
import SwiftUI

// MARK: - Persisted draft

/// Codable per-workspace draft: everything collapsing must preserve.
struct LatticeDraftState: Codable, Sendable, Equatable {
    var prompt: String = ""
    var configuration = LatticeConfiguration()
    var isExpanded: Bool = true
    var activeView: LatticeWorkspaceView = .lattice
    var suggestionsApplied: Bool = false
}

// MARK: - Store

/// Single source of truth for the Intent Lattice screen. Every counter,
/// summary, validation, plan, and manifest derives from THIS store — no
/// view keeps its own copy of selection state.
///
/// Superposition (parallel configuration branches) is capability-gated:
/// the runtime executes one configuration at a time, so the feature is
/// honestly reported as unavailable rather than shipped as a dead toggle.
@MainActor
@Observable
final class IntentLatticeStore {

    // MARK: Draft (editable)

    var prompt: String = "" {
        didSet { schedulePersist(); recompute() }
    }
    var configuration: LatticeConfiguration = LatticeConfiguration() {
        didSet { schedulePersist(); recompute() }
    }
    var isExpanded: Bool = true {
        didSet { schedulePersist() }
    }
    var activeView: LatticeWorkspaceView = .lattice {
        didSet { schedulePersist() }
    }
    /// Inspector focus (keyboard-navigable selected cell).
    var selectedCell: LatticeCellID?
    /// Focused cell for keyboard navigation (may differ from inspector cell).
    var focusedCell: LatticeCellID?

    // MARK: Derived (never stored twice)

    private(set) var availabilityInput = LatticeAvailabilityInput(
        hasWorkspace: false, attachedFileCount: 0, isGitRepo: false,
        hasDocumentation: false, hasTestTargets: false, builtInToolCount: 0,
        mcpServerCount: 0, memoryEnabled: false)
    private(set) var projection = LatticeTokenProjection(
        promptTokens: 0, contextTokens: 0, reservedOutputTokens: 0,
        totalProjected: 0, contextWindow: nil, usableWindow: nil,
        remaining: nil, utilization: nil)
    private(set) var validation = LatticeValidation(canRun: false, blockers: ["Choose a model before running."])
    private(set) var suggestion: LatticeSuggestions.Result?
    private(set) var applicableSuggestions: [LatticeCellID] = []
    private(set) var presetSkips: [(cell: LatticeCellID, reason: String)] = []

    // MARK: Run state

    private(set) var phase: LatticePhase = .idle
    private(set) var currentRun: LatticeRunSnapshot?
    private(set) var stageStatus: [String: LatticeExecutionStage] = [:]

    // MARK: Superposition — capability gate (Option B, honest)

    static let superpositionSupported = false
    static let superpositionExplanation =
        "Parallel configuration comparison is not available for this runtime — runs execute one configuration at a time."

    // MARK: Private

    private var controller: AgentSessionController?
    private var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    private var persistTask: Task<Void, Never>?
    private var workspaceKey: String?

    let reservedOutputTokens = 4_096

    // MARK: Wiring

    /// Attached files — single source of truth shared with the composer.
    var attachments: [ComposerAttachment] = [] {
        didSet { refreshAvailability() }
    }

    func attach(controller: AgentSessionController, appState: AppState) {
        self.controller = controller
        self.appState = appState

        // Live phase from the real agent events — never simulated.
        // NOTE: .receive(on: RunLoop.main) is load-bearing. Verified under
        // XCTest: a direct sink never delivers here (the store is @MainActor
        // and the subscription is created off the run loop), while the
        // RunLoop hop delivers promptly because XCTest pumps the main run
        // loop for async tests — same mechanism the app's main thread uses.
        controller.$isRunning
            .combineLatest(controller.$currentPhase, controller.$finishReason)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.syncPhase() }
            .store(in: &cancellables)
        controller.$workspaceURL
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.workspaceDidChange() }
            .store(in: &cancellables)
        settingsCancellable()

        workspaceDidChange()
    }

    private func settingsCancellable() {
        SettingsStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAvailability() }
            .store(in: &cancellables)
    }

    // MARK: Availability — driven by REAL application state

    private func workspaceDidChange() {
        guard let controller else { return }
        let workspace = controller.workspaceURL
        workspaceKey = workspace?.path
        loadDraft(for: workspace)
        refreshAvailability()
    }

    func refreshAvailability() {
        guard let controller else { return }
        let workspace = controller.workspaceURL
        let settings = SettingsStore.shared
        var isGit = false
        var hasDocs = false
        var hasTests = false
        if let workspace {
            let fm = FileManager.default
            isGit = fm.fileExists(atPath: workspace.appendingPathComponent(".git").path)
            hasDocs = fm.fileExists(atPath: workspace.appendingPathComponent("docs").path)
                || fm.fileExists(atPath: workspace.appendingPathComponent("README.md").path)
                || fm.fileExists(atPath: workspace.appendingPathComponent("AGENTS.md").path)
            hasTests = Self.discoverTestTargets(in: workspace)
        }
        availabilityInput = LatticeAvailabilityInput(
            hasWorkspace: workspace != nil,
            attachedFileCount: attachments.count,
            isGitRepo: isGit,
            hasDocumentation: hasDocs,
            hasTestTargets: hasTests,
            builtInToolCount: AgentSessionController.defaultTools.count,
            mcpServerCount: 0,  // filled from live MCP config when wired
            memoryEnabled: settings.memoryMode != .off)
        recompute()
    }

    /// Cheap, bounded test-target discovery: SwiftPM test targets, an
    /// Xcode project, or a Tests/ directory.
    private static func discoverTestTargets(in root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Tests").path) { return true }
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if items.contains(where: { $0.pathExtension == "xcodeproj" }) { return true }
        }
        if let package = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) {
            return package.contains("testTarget")
        }
        return false
    }

    func availability(for layer: ContextLayer) -> CellAvailability {
        ContextAvailability.availability(for: layer, input: availabilityInput)
    }

    // MARK: Selection mutations

    /// Single click: toggle an available cell. Unavailable cells are never
    /// selectable — the UI disables them and explains why.
    func toggle(_ id: LatticeCellID) {
        guard availability(for: id.context) == .available else { return }
        if configuration.isSelected(id) {
            configuration.cells[id.key] = nil
        } else {
            configuration.cells[id.key] = LatticeCellSelection(id: id, source: .manual)
        }
    }

    func select(_ id: LatticeCellID, source: SelectionSource = .manual) {
        guard availability(for: id.context) == .available else { return }
        configuration.cells[id.key] = LatticeCellSelection(id: id, source: source)
    }

    func deselect(_ id: LatticeCellID) {
        configuration.cells[id.key] = nil
    }

    func setWeight(_ id: LatticeCellID, _ weight: Double) {
        guard var selection = configuration.cells[id.key] else { return }
        selection.weight = min(max(weight, 0), 1)
        configuration.cells[id.key] = selection
    }

    func setNote(_ id: LatticeCellID, _ note: String) {
        guard var selection = configuration.cells[id.key] else { return }
        selection.note = note.isEmpty ? nil : note
        configuration.cells[id.key] = selection
    }

    func clearAll() {
        configuration = LatticeConfiguration()
        presetSkips = []
    }

    // MARK: Presets

    func applyPreset(_ preset: LatticePreset) {
        let (config, skipped) = preset.apply { [weak self] layer in
            self?.availability(for: layer) ?? .available
        }
        configuration = config
        presetSkips = skipped
        recompute()
    }

    // MARK: Suggestions

    func refreshSuggestions() {
        guard let result = LatticeSuggestions.analyze(prompt) else {
            suggestion = nil
            applicableSuggestions = []
            return
        }
        suggestion = result
        applicableSuggestions = LatticeSuggestions.applicable(
            result, configuration: configuration) { [weak self] layer in
            self?.availability(for: layer) ?? .available
        }
    }

    /// Explicit action — suggestions never auto-activate.
    func applySuggestions() {
        for id in applicableSuggestions {
            select(id, source: .suggested)
        }
        applicableSuggestions = []
    }

    // MARK: Token projection (real derived values, labeled estimates)

    private func recompute() {
        let window = appState?.activeModel?.contextWindow
        let usable = window.map { max(1, $0 - reservedOutputTokens) }

        let promptTokens = LatticeEngine.estimateTokens(prompt)
        var contextTokens = 0
        for selection in configuration.selections {
            contextTokens += LatticeEngine.estimateTokens(selection.id.role.instruction)
            contextTokens += LatticeEngine.estimateTokens(resolvedContextText(selection.id.context))
            if let note = selection.note { contextTokens += LatticeEngine.estimateTokens(note) }
        }
        let total = promptTokens + contextTokens + reservedOutputTokens
        projection = LatticeTokenProjection(
            promptTokens: promptTokens,
            contextTokens: contextTokens,
            reservedOutputTokens: reservedOutputTokens,
            totalProjected: total,
            contextWindow: window,
            usableWindow: usable,
            remaining: usable.map { max(0, $0 - total) },
            utilization: usable.map { Double(total) / Double($0) })

        refreshSuggestions()

        validation = LatticeValidator.validate(
            prompt: prompt,
            configuration: configuration,
            modelReady: appState?.isModelReady ?? false,
            modelLoading: appState?.isModelLoading ?? false,
            hasWorkspace: controller?.workspaceURL != nil,
            projection: projection,
            runActive: controller?.isRunning ?? false)
    }

    /// Resolves real content for a context layer (real workspace state via ContextResolvers), used for both token math and the run manifest.
    func resolvedContextText(_ layer: ContextLayer) -> String {
        guard let workspace = controller?.workspaceURL else { return "" }
        switch layer {
        case .openFiles:
            return ""  // attachments travel with the message, not the manifest
        case .codebase:
            return "workspace \(workspace.lastPathComponent)"
        case .documentation:
            return ContextResolvers.documentationContext(workspace: workspace)
        case .git:
            return ContextResolvers.gitContext(workspace: workspace)
        case .terminal:
            return "command execution permitted for this role (approval policy still applies)"
        case .memory:
            return "project memory enabled"
        case .tools:
            return "\(AgentSessionController.defaultTools.count) built-in tools available"
        case .tests:
            return availabilityInput.hasTestTargets
                ? "test targets discovered in this workspace" : ""
        }
    }

    // MARK: Run lifecycle

    /// Validate → snapshot → freeze → manifest → start the real run.
    /// `sender` performs the actual dispatch (the UI supplies it so
    /// attachments and queueing stay in the composer). Returns the blocking
    /// reason when the commit is refused.
    @discardableResult
    func commitRun(sender: (String) -> Void) -> String? {
        recompute()
        guard validation.canRun else { return validation.primaryBlocker ?? "Cannot run." }
        guard let controller, let appState else { return "Runtime is not attached." }
        guard let workspace = controller.workspaceURL else { return "Open a workspace first." }
        let modelID: String
        let modelDisplayName: String
        if let model = appState.activeModel {
            modelID = model.id
            modelDisplayName = model.displayName
        } else if appState.isRemoteActive,
                  let endpoint = appState.engine.activeRemoteEndpoint {
            modelID = endpoint.provider.rawValue + ":" + endpoint.model
            modelDisplayName = endpoint.provider.displayName + " · " + endpoint.model
        } else {
            return "Choose a model before running."
        }

        phase = .preflighting
        let plan = LatticeRunSnapshot.buildPlan(configuration)
        let snapshot = LatticeRunSnapshot(
            prompt: prompt,
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            workspacePath: workspace.path,
            configuration: configuration,
            plan: plan,
            projection: projection)
        currentRun = snapshot
        stageStatus = Dictionary(uniqueKeysWithValues:
            plan.map { ($0.role.rawValue, LatticeExecutionStage.pending) })

        // Manifest: ONLY granted contexts, built from the frozen snapshot.
        let manifest = LatticeManifestBuilder.build(
            configuration: snapshot.configuration,
            resolvedContexts: { [weak self] layer in self?.resolvedContextText(layer) ?? "" },
            draft: snapshot.prompt) ?? snapshot.prompt

        sender(manifest)
        phase = .running
        for role in plan { stageStatus[role.role.rawValue] = .active }
        return nil
    }

    func cancelRun() {
        guard phase == .running || phase == .awaitingApproval else { return }
        phase = .cancelling
        controller?.stop()
    }

    /// Maps real controller state onto lattice phases + stage statuses.
    ///
    /// Robust to Combine event order: `finishReason` publishes before
    /// `isRunning` flips false at the end of a run, so terminal state is
    /// derived from finishReason first — never from an ordering assumption.
    private func syncPhase() {
        guard let controller else { return }

        // 1. A cancellation that has landed is terminal — either signal
        //    (finish reason arrived OR the run stopped) counts, in any order.
        if phase == .cancelling, !controller.isRunning || controller.finishReason != nil {
            phase = .failed
            finishStages(.skipped)
            return
        }

        // 2. Live run — still executing. `.cancelling` is sticky: a stale
        //    publisher event fired by the stop() sequence must never
        //    downgrade the phase back to .running mid-cancel.
        if controller.isRunning, controller.finishReason == nil {
            if phase == .cancelling { return }
            switch controller.currentPhase {
            case .awaitingApproval, .awaitingPlanApproval, .awaitingQuestion:
                phase = .awaitingApproval
            default:
                phase = .running
            }
            return
        }

        // 3. Terminal state derived from the real finish reason.
        //    Idempotent: once a run reached a terminal phase, later
        //    publisher events must NOT re-mark the stages (the RunLoop
        //    sink delivers finishReason and isRunning as separate events).
        if phase == .completed || phase == .failed { return }
        switch controller.finishReason {
        case .completed:
            phase = .completed
            finishStages(.completed)
        case .some:
            phase = .failed
            finishStages(.failed)
        case nil:
            phase = configuration.cells.isEmpty ? .idle : .ready
        }
    }

    private func finishStages(_ stage: LatticeExecutionStage) {
        for key in stageStatus.keys { stageStatus[key] = stage }
    }

    // MARK: Persistence (per workspace, validated on restore)

    /// Test seam: redirect draft persistence into a temp dir so tests never
    /// touch the developer's real Application Support (same pattern as
    /// ModelStore.overrideModelsDir).
    static var overrideDraftsDir: URL?

    private var draftFileURL: URL? {
        guard let key = workspaceKey else { return nil }
        let dir: URL
        if let base = Self.overrideDraftsDir {
            dir = base.appendingPathComponent("LatticeDrafts", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeetCode/LatticeDrafts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stable filename from the workspace path.
        let digest = key.unicodeScalars.reduce(into: UInt64(5381)) { acc, s in
            acc = (acc &* 33) &+ UInt64(s.value)
        }
        return dir.appendingPathComponent("draft-\(digest).json")
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard let url = draftFileURL else { return }
        let state = LatticeDraftState(
            prompt: prompt,
            configuration: configuration,
            isExpanded: isExpanded,
            activeView: activeView)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadDraft(for workspace: URL?) {
        guard let url = draftFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LatticeDraftState.self, from: data)
        else {
            prompt = ""
            configuration = LatticeConfiguration()
            isExpanded = true
            activeView = .lattice
            currentRun = nil
            phase = .idle
            return
        }
        prompt = state.prompt
        configuration = state.configuration
        isExpanded = state.isExpanded
        activeView = state.activeView
        currentRun = nil
        phase = configuration.cells.isEmpty ? .idle : .ready
        // Selections of now-unavailable layers remain visible but disabled —
        // they can never execute because commitRun re-validates everything.
        recompute()
        _ = workspace
    }

    // MARK: Header summaries (single derived source)

    var collapsedSummary: String {
        let roles = configuration.activeRoles.count
        let contexts = Set(configuration.selections.map(\.id.context)).count
        let model = appState?.activeModel?.displayName ?? "No model"
        var parts = ["\(roles) role\(roles == 1 ? "" : "s")", "\(contexts) context\(contexts == 1 ? "" : "s")", model]
        if let utilization = projection.utilization {
            parts.append("\(Int(utilization * 100))% context budget")
        }
        return parts.joined(separator: " · ")
    }

    var selectedCellCount: Int { configuration.cells.count }
}

// MARK: - AppState readiness bridge

extension AppState {
    var isModelReady: Bool {
        if case .ready = enginePhase { return true }
        return isRemoteActive
    }
    var isModelLoading: Bool {
        if case .loading = enginePhase { return true }
        return false
    }
}
