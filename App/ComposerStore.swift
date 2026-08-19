import Combine
import Foundation
import SwiftUI

// MARK: - Persisted draft

/// Codable per-workspace draft: the prompt text plus the intent selection.
/// Attachments are deliberately not persisted (they point at live files).
struct ComposerDraftState: Codable, Sendable, Equatable {
    var prompt: String = ""
    var selection = IntentSelection()
}

// MARK: - Store

/// Single source of truth for the composer screen: the draft prompt, the
/// attachments, and the per-turn Intent (roles + focus) that prefixes the
/// outgoing message. Views never keep their own copy of this state.
///
/// Compared to the Intent Lattice it replaces: two binary chip rows instead
/// of a 48-cell matrix, no weights/muted states/superposition, and honest
/// token telemetry (≈ chars/4 against the model's real context window).
@MainActor
@Observable
final class ComposerStore {

    // MARK: Draft (editable)

    var prompt: String = "" {
        didSet { schedulePersist(); recomputeEstimate() }
    }
    var attachments: [ComposerAttachment] = [] {
        didSet { refreshAvailability(); refreshResolvedFocus() }
    }
    var selection: IntentSelection = IntentSelection() {
        didSet { schedulePersist(); refreshResolvedFocus() }
    }

    // MARK: Derived (never stored twice)

    private(set) var focusAvailability: [FocusSource: FocusAvailability] = [:]
    private(set) var estimate = TokenEstimate(
        draftTokens: 0, intentTokens: 0, focusTokens: 0, attachmentTokens: 0,
        totalTokens: 0, contextWindow: nil, utilization: nil)

    struct TokenEstimate: Sendable, Equatable {
        var draftTokens: Int
        var intentTokens: Int
        var focusTokens: Int
        var attachmentTokens: Int
        var totalTokens: Int
        /// The loaded local model's context window; nil for remote engines
        /// (unknown → no percentage, per the honesty rule).
        var contextWindow: Int?
        var utilization: Double?
    }

    /// Resolved focus content, cached so typing never shells out to git.
    /// Refreshed when the selection/attachments/workspace change; re-resolved
    /// fresh at send time.
    private(set) var resolvedFocusCache: [FocusSource: String] = [:]

    // MARK: Private

    private var controller: AgentSessionController?
    private var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    private var persistTask: Task<Void, Never>?
    private var workspaceKey: String?
    private var lastEstimateRefresh = Date.distantPast
    /// Captured persist that has not yet hit disk. Flushed synchronously on
    /// workspace switch so a cancelled debounce cannot drop the old draft.
    private var pendingPersist: (url: URL, state: ComposerDraftState)?
    private var isLoadingDraft = false

    // MARK: Wiring

    func attach(controller: AgentSessionController, appState: AppState) {
        self.controller = controller
        self.appState = appState

        // Task { @MainActor } delivers under XCTest's cooperative executor;
        // `.receive(on: RunLoop.main)` can sit unprocessed for seconds in
        // async tests and flake draft restore on workspace switch.
        controller.$workspaceURL
            .sink { [weak self] _ in
                Task { @MainActor in self?.workspaceDidChange() }
            }
            .store(in: &cancellables)

        // The estimate's denominator depends on the active model; throttled
        // so per-token objectWillChange storms can't recompute on every token.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastEstimateRefresh) > 1 else { return }
                self.lastEstimateRefresh = now
                self.recomputeEstimate()
            }
            .store(in: &cancellables)

        workspaceDidChange()
    }

    // MARK: Availability — driven by REAL application state

    private func workspaceDidChange() {
        flushPersistNow()
        workspaceKey = controller?.workspaceURL?.path
        loadDraft(for: controller?.workspaceURL)
        refreshAvailability()
    }

    func refreshAvailability() {
        let workspace = controller?.workspaceURL
        let fm = FileManager.default
        var map: [FocusSource: FocusAvailability] = [:]

        map[.files] = attachments.isEmpty
            ? .unavailable(reason: "Attach a file first — @files quotes the attachments of this message.")
            : .available

        guard let workspace else {
            map[.git] = .unavailable(reason: "Open a project folder first.")
            map[.docs] = .unavailable(reason: "Open a project folder first.")
            map[.codebase] = .unavailable(reason: "Open a project folder first.")
            focusAvailability = map
            return
        }

        map[.git] = ContextResolvers.isGitRepo(workspace)
            ? .available
            : .unavailable(reason: "The selected folder is not a git repository.")
        let hasDocs = fm.fileExists(atPath: workspace.appendingPathComponent("docs").path)
            || !ContextResolvers.markdownNames(in: workspace).isEmpty
        map[.docs] = hasDocs
            ? .available
            : .unavailable(reason: "No README or docs/*.md found in this workspace.")
        map[.codebase] = .available

        focusAvailability = map
    }

    func availability(for source: FocusSource) -> FocusAvailability {
        focusAvailability[source] ?? .unavailable(reason: "Unavailable.")
    }

    // MARK: Selection mutations — binary, availability-gated for focus

    func toggleRole(_ role: IntentRole) {
        if selection.roles.contains(role) {
            selection.roles.remove(role)
        } else {
            selection.roles.insert(role)
        }
    }

    func toggleFocus(_ source: FocusSource) {
        if selection.focus.contains(source) {
            selection.focus.remove(source)
        } else {
            guard availability(for: source).isAvailable else { return }
            selection.focus.insert(source)
        }
    }

    /// Presets replace the role selection; focus is workspace-dependent and
    /// left untouched.
    func applyPreset(_ preset: IntentPreset) {
        selection.roles = Set(preset.roles)
    }

    func clearIntent() {
        selection = IntentSelection()
    }

    // MARK: Resolved focus content

    /// Fresh resolution — used at send time so the injected content reflects
    /// the workspace as it is right now.
    func resolvedFocus(_ source: FocusSource) -> String {
        switch source {
        case .files:
            return attachments.map(\.name).joined(separator: ", ")
        case .git:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.gitContext(workspace: workspace)
        case .docs:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.documentationContext(workspace: workspace)
        case .codebase:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.codebaseContext(workspace: workspace)
        }
    }

    /// Cache refresh: recomputes only the selected sources, and only fires on
    /// selection/attachment/workspace changes — never on prompt keystrokes,
    /// so typing can never spawn a git process.
    private func refreshResolvedFocus() {
        var cache: [FocusSource: String] = [:]
        for source in selection.orderedFocus {
            cache[source] = resolvedFocus(source)
        }
        resolvedFocusCache = cache
        recomputeEstimate()
    }

    // MARK: Token estimate (honest: ≈ chars/4 against the real window)

    private func recomputeEstimate() {
        let draftTokens = IntentTokens.estimate(prompt)
        let intentTokens = selection.orderedRoles.reduce(0) { $0 + IntentTokens.estimate($1.instruction) }
        let focusTokens = selection.orderedFocus.reduce(0) { $0 + IntentTokens.estimate(resolvedFocusCache[$1] ?? "") }
        let attachmentTokens = attachments.reduce(0) { $0 + estimatedAttachmentTokens($1) }
        let total = draftTokens + intentTokens + focusTokens + attachmentTokens

        // The engine's REAL launched window (GGUF fits ctx to RAM) is the
        // honest denominator; the catalog value is the fallback.
        let window = appState?.effectiveContextWindow ?? appState?.activeModel?.contextWindow
        // The denominator is the window minus the response reserve; when the
        // window is unknown (remote engine) there is no percentage, by design.
        let reserve = 4_096
        let utilization = window.map { Double(total) / Double(max(1, $0 - reserve)) }

        estimate = TokenEstimate(
            draftTokens: draftTokens, intentTokens: intentTokens,
            focusTokens: focusTokens, attachmentTokens: attachmentTokens,
            totalTokens: total, contextWindow: window, utilization: utilization)
    }

    /// Matches what the send pipeline actually injects: text attachments are
    /// quoted up to a 16 KB cap (larger files degrade to a path note), and
    /// images contribute their vision description.
    private func estimatedAttachmentTokens(_ attachment: ComposerAttachment) -> Int {
        if attachment.isImage { return 300 }
        let size = (try? FileManager.default.attributesOfItem(atPath: attachment.url.path))?[.size] as? Int
        guard let size, size > 0 else { return 25 }
        return size < 16_384 ? max(1, (size + 3) / 4) : 25
    }

    // MARK: Validation + send

    /// The single reason the composer can't send right now, or nil. Slash
    /// commands bypass this entirely (they run locally).
    var sendBlocker: String? {
        if controller?.workspaceURL == nil { return "Open a project folder first" }
        if appState?.isModelLoading == true { return "Model is loading…" }
        if appState?.isModelReady != true { return "Choose a model to run" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the task first" }
        return nil
    }

    var canSend: Bool {
        sendBlocker == nil && controller?.isRunning == false
    }

    /// Slash → local command; otherwise compose the intent block and dispatch
    /// the real run. A successful dispatch is one-shot: prompt, attachments,
    /// and the intent selection all clear.
    @discardableResult
    func send() -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if text.hasPrefix("/") {
            guard let controller, controller.handleSlash(text) else { return false }
            prompt = ""
            return true
        }

        guard let controller, canSend else { return false }
        let composed = IntentComposer.compose(selection: selection, draft: text) { [weak self] source in
            self?.resolvedFocus(source) ?? ""
        }
        let outgoing = attachments
        controller.send(composed, attachments: outgoing)
        prompt = ""
        attachments = []
        selection = IntentSelection()
        return true
    }

    // MARK: Persistence (per workspace, validated on restore)

    /// Test seam: redirect draft persistence into a temp dir so tests never
    /// touch the developer's real Application Support.
    static var overrideDraftsDir: URL?

    private var draftFileURL: URL? {
        guard let key = workspaceKey else { return nil }
        let dir: URL
        if let base = Self.overrideDraftsDir {
            dir = base.appendingPathComponent("ComposerDrafts", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeetCode/ComposerDrafts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stable filename from the workspace path.
        let digest = key.unicodeScalars.reduce(into: UInt64(5381)) { acc, s in
            acc = (acc &* 33) &+ UInt64(s.value)
        }
        return dir.appendingPathComponent("draft-\(digest).json")
    }

    private func schedulePersist() {
        if isLoadingDraft { return }
        persistTask?.cancel()
        guard let url = draftFileURL else { return }
        let state = ComposerDraftState(prompt: prompt, selection: selection)
        pendingPersist = (url, state)
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.persist(state, to: url)
            if pendingPersist?.url == url { pendingPersist = nil }
        }
    }

    /// Write any in-flight draft immediately. Called before rekeying so a
    /// workspace switch cannot cancel the debounce and lose the old file.
    private func flushPersistNow() {
        persistTask?.cancel()
        persistTask = nil
        if let pending = pendingPersist {
            Self.persist(pending.state, to: pending.url)
            pendingPersist = nil
        }
    }

    private static func persist(_ state: ComposerDraftState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadDraft(for workspace: URL?) {
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        guard let url = draftFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ComposerDraftState.self, from: data)
        else {
            prompt = ""
            selection = IntentSelection()
            return
        }
        prompt = state.prompt
        selection = state.selection
        _ = workspace
    }
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
