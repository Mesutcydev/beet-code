import XCTest
@testable import BeetCode

/// Comprehensive tests for the repaired Intent Lattice system, covering the
/// 20 required scenarios: selection, availability gating, suggestions,
/// presets, weights, token budget, validation, run eligibility, immutable
/// snapshots, collapse preservation, session restoration, superposition
/// capability gate, granted-only manifests, and cancel/failure recovery.
///
/// Two layers:
///   A. Pure logic (ContextAvailability, LatticeValidator, presets,
///      suggestions, snapshot, manifest) — no app objects.
///   B. Store integration — real temp git workspace, FakeLLMEngine, no
///      network, no weights, no Metal.

// MARK: - A. Pure logic

final class IntentLatticeLogicTests: XCTestCase {

    private let fullInput = LatticeAvailabilityInput(
        hasWorkspace: true, attachedFileCount: 1, isGitRepo: true,
        hasDocumentation: true, hasTestTargets: true, builtInToolCount: 8,
        mcpServerCount: 0, memoryEnabled: true)

    // Scenario: availability reasons + recovery actions (exact, actionable)

    func testAvailabilityGitWithoutRepoExplainsAndOffersRecovery() {
        var input = fullInput
        input.isGitRepo = false
        guard case .unavailable(let reason, let recovery) =
            ContextAvailability.availability(for: .git, input: input) else {
            return XCTFail("git must be unavailable without a repo")
        }
        XCTAssertTrue(reason.contains("not a git repository"))
        XCTAssertEqual(recovery, "Initialize Repository")
    }

    func testAvailabilityOpenFilesRequiresAttachments() {
        var input = fullInput
        input.attachedFileCount = 0
        guard case .unavailable(let reason, let recovery) =
            ContextAvailability.availability(for: .openFiles, input: input) else {
            return XCTFail("openFiles must be unavailable without attachments")
        }
        XCTAssertTrue(reason.contains("No files"))
        XCTAssertNotNil(recovery)
    }

    func testAvailabilityMemoryOffPointsAtSettings() {
        var input = fullInput
        input.memoryEnabled = false
        guard case .unavailable(_, let recovery) =
            ContextAvailability.availability(for: .memory, input: input) else {
            return XCTFail("memory must be unavailable when disabled")
        }
        XCTAssertTrue(recovery?.contains("Enable Project Memory") == true)
    }

    func testAvailabilityToolsRequiresRegisteredTools() {
        var input = fullInput
        input.builtInToolCount = 0
        input.mcpServerCount = 0
        guard case .unavailable(_, let recovery) =
            ContextAvailability.availability(for: .tools, input: input) else {
            return XCTFail("tools must be unavailable with zero tools")
        }
        XCTAssertEqual(recovery, "Connect Tools")
    }

    func testAvailabilityWorkspaceDependentLayersWithoutWorkspace() {
        var input = fullInput
        input.hasWorkspace = false
        for layer in [ContextLayer.codebase, .terminal, .documentation, .git, .tests] {
            guard case .unavailable(_, let recovery) =
                ContextAvailability.availability(for: layer, input: input) else {
                return XCTFail("\(layer) must be unavailable without a workspace")
            }
            XCTAssertEqual(recovery, "Choose Workspace")
        }
    }

    func testAvailabilityTestsRequiresDiscoveredTargets() {
        var input = fullInput
        input.hasTestTargets = false
        guard case .unavailable(_, let recovery) =
            ContextAvailability.availability(for: .tests, input: input) else {
            return XCTFail("tests must be unavailable without targets")
        }
        XCTAssertEqual(recovery, "Discover Tests")
    }

    // Scenario: presets respect availability — skips are visible, never silent

    func testPresetAppliesFullyWhenEverythingAvailable() {
        let preset = LatticePresets.preset(id: "balanced-build")!
        let (config, skipped) = preset.apply { _ in .available }
        XCTAssertEqual(config.cells.count, preset.cells.count)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(config.presetID, "balanced-build")
        for selection in config.selections {
            XCTAssertEqual(selection.source, .preset)
            XCTAssertEqual(selection.weight, 1.0)
        }
    }

    func testPresetSkipsUnavailableCellsWithReasons() {
        let preset = LatticePresets.preset(id: "balanced-build")!
        let (config, skipped) = preset.apply { layer in
            // No git repo, no tests discovered.
            switch layer {
            case .git: .unavailable(reason: "The selected folder is not a git repository.", recovery: "Initialize Repository")
            case .tests: .unavailable(reason: "No test targets discovered in this workspace.", recovery: "Discover Tests")
            default: .available
            }
        }
        let skippedContexts = Set(skipped.map(\.cell.context))
        XCTAssertTrue(skippedContexts.contains(.git))
        XCTAssertTrue(skippedContexts.contains(.tests))
        for reason in skipped.map(\.reason) {
            XCTAssertFalse(reason.isEmpty, "every skip must carry a visible reason")
        }
        // Skipped cells must NOT appear as selected.
        for selection in config.selections {
            XCTAssertNotEqual(selection.id.context, .git)
            XCTAssertNotEqual(selection.id.context, .tests)
        }
    }

    // Scenario: suggestions are deterministic and never auto-activate

    func testSuggestionsAreDeterministicPerIntent() {
        XCTAssertEqual(LatticeSuggestions.analyze("implement a cache")?.ruleName, "Build-oriented task")
        XCTAssertEqual(LatticeSuggestions.analyze("fix the crash")?.ruleName, "Debug-oriented task")
        XCTAssertEqual(LatticeSuggestions.analyze("review this change")?.ruleName, "Review-oriented task")
        XCTAssertEqual(LatticeSuggestions.analyze("research options")?.ruleName, "Research-oriented task")
        XCTAssertNil(LatticeSuggestions.analyze("hello there"), "no rule → no suggestions")
    }

    func testSuggestionsRespectAvailabilityAndExistingSelections() {
        let result = LatticeSuggestions.analyze("fix the bug")!
        var config = LatticeConfiguration()
        let builderCodebase = LatticeCellID(.builder, .codebase)
        config.cells[builderCodebase.key] = LatticeCellSelection(id: builderCodebase)
        let applicable = LatticeSuggestions.applicable(result, configuration: config) { layer in
            // Terminal unavailable → suggestions must not offer it.
            layer == .terminal
                ? .unavailable(reason: "No workspace is open.", recovery: "Choose Workspace")
                : .available
        }
        XCTAssertFalse(applicable.contains(builderCodebase), "already-selected cells drop out")
        XCTAssertFalse(applicable.contains(LatticeCellID(.builder, .terminal)),
                       "unavailable layers must never be suggested")
        XCTAssertFalse(applicable.isEmpty)
    }

    // Scenarios: token budget + validation (single source of run eligibility)

    func testValidatorBlocksOnNoModel() {
        let validation = LatticeValidator.validate(
            prompt: "do it", configuration: configured(),
            modelReady: false, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertFalse(validation.canRun)
        XCTAssertEqual(validation.primaryBlocker, "Choose a model before running.")
    }

    func testValidatorBlocksOnNoWorkspace() {
        let validation = LatticeValidator.validate(
            prompt: "do it", configuration: configured(),
            modelReady: true, modelLoading: false, hasWorkspace: false,
            projection: fits(), runActive: false)
        XCTAssertFalse(validation.canRun)
        XCTAssertTrue(validation.blockers.contains { $0.contains("Open a workspace") })
    }

    func testValidatorBlocksOnEmptyPromptAndRunActiveAndLoading() {
        let emptyPrompt = LatticeValidator.validate(
            prompt: "   ", configuration: configured(),
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertTrue(emptyPrompt.blockers.contains { $0.contains("Describe the task") })

        let active = LatticeValidator.validate(
            prompt: "do it", configuration: configured(),
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: true)
        XCTAssertTrue(active.blockers.contains { $0.contains("already in progress") })

        let loading = LatticeValidator.validate(
            prompt: "do it", configuration: configured(),
            modelReady: false, modelLoading: true, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertTrue(loading.blockers.contains { $0.contains("still loading") })
    }

    func testValidatorRequiresConfigurationOrPreset() {
        let bare = LatticeValidator.validate(
            prompt: "do it", configuration: LatticeConfiguration(),
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertTrue(bare.blockers.contains { $0.contains("Apply a preset") })

        // "Minimal Context" preset = explicit empty selection → allowed.
        var explicit = LatticeConfiguration()
        explicit.presetID = "minimal-context"
        let presetEmpty = LatticeValidator.validate(
            prompt: "do it", configuration: explicit,
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertTrue(presetEmpty.canRun, "an explicit preset choice must not be re-blocked")
    }

    func testValidatorBlocksWhenProjectedExceedsUsableWindow() {
        let over = LatticeTokenProjection(
            promptTokens: 100, contextTokens: 5_000, reservedOutputTokens: 4_096,
            totalProjected: 9_196, contextWindow: 8_192, usableWindow: 4_096,
            remaining: 0, utilization: 9_196.0 / 4_096.0)
        let validation = LatticeValidator.validate(
            prompt: "do it", configuration: configured(),
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: over, runActive: false)
        XCTAssertFalse(validation.canRun)
        let blocker = validation.blockers.first { $0.contains("exceeding") }
        XCTAssertNotNil(blocker)
        // Cite the REAL numbers — format-agnostic: compare against the same
        // locale-aware formatter the validator uses.
        XCTAssertTrue(blocker!.contains(9_196.formatted()), "blocker must cite real numbers")
        XCTAssertTrue(blocker!.contains(4_096.formatted()))
    }

    func testValidatorHappyPath() {
        let validation = LatticeValidator.validate(
            prompt: "implement feature X", configuration: configured(),
            modelReady: true, modelLoading: false, hasWorkspace: true,
            projection: fits(), runActive: false)
        XCTAssertTrue(validation.canRun)
        XCTAssertTrue(validation.blockers.isEmpty)
    }

    // Scenario: weights clamp to 0…1 at the type level

    func testSelectionWeightClamps() {
        let id = LatticeCellID(.planner, .codebase)
        XCTAssertEqual(LatticeCellSelection(id: id, weight: 1.7).weight, 1.0)
        XCTAssertEqual(LatticeCellSelection(id: id, weight: -0.4).weight, 0.0)
        XCTAssertEqual(LatticeCellSelection(id: id, weight: 0.42).weight, 0.42)
    }

    // Scenario: immutable run snapshot — frozen at commit time

    func testSnapshotIsImmutableAcrossLaterEdits() {
        var config = LatticeConfiguration()
        let plannerCodebase = LatticeCellID(.planner, .codebase)
        config.cells[plannerCodebase.key] = LatticeCellSelection(id: plannerCodebase)
        let plan = LatticeRunSnapshot.buildPlan(config)
        let snapshot = LatticeRunSnapshot(
            prompt: "task", modelID: "m", modelDisplayName: "M",
            workspacePath: "/w", configuration: config, plan: plan,
            projection: fits())

        // Edit the live configuration AFTER the snapshot.
        let testerTests = LatticeCellID(.tester, .tests)
        config.cells[testerTests.key] = LatticeCellSelection(id: testerTests)

        XCTAssertEqual(snapshot.configuration.cells.count, 1, "snapshot must stay frozen")
        XCTAssertEqual(snapshot.plan.count, 1)
        XCTAssertNotEqual(snapshot.configuration, config, "draft keeps evolving separately")
    }

    // Scenario: execution manifest contains ONLY granted contexts

    func testManifestContainsOnlyGrantedContexts() {
        var config = LatticeConfiguration()
        config.cells[LatticeCellID(.builder, .codebase).key] =
            LatticeCellSelection(id: LatticeCellID(.builder, .codebase))
        config.cells[LatticeCellID(.reviewer, .git).key] =
            LatticeCellSelection(id: LatticeCellID(.reviewer, .git), weight: 0.5)

        let manifest = LatticeManifestBuilder.build(
            configuration: config,
            resolvedContexts: { layer in
                switch layer {
                case .codebase: "workspace fixture-repo"
                case .git: "branch: main"
                default: "LEAKED-\(layer.rawValue)"
                }
            },
            draft: "implement the change")!

        XCTAssertTrue(manifest.contains("Builder"))
        XCTAssertTrue(manifest.contains("Reviewer"))
        XCTAssertTrue(manifest.contains("workspace fixture-repo"))
        XCTAssertTrue(manifest.contains("branch: main"))
        XCTAssertTrue(manifest.contains("implement the change"))
        XCTAssertFalse(manifest.contains("LEAKED-"), "ungranted layers must never be resolved")
        XCTAssertFalse(manifest.contains("Tester"), "unconfigured roles must not appear")
    }

    func testManifestIsNilForEmptyConfiguration() {
        XCTAssertNil(LatticeManifestBuilder.build(
            configuration: LatticeConfiguration(),
            resolvedContexts: { _ in "x" },
            draft: "task"))
    }

    func testOrchestratorIsMarkedCoordinationOnlyInManifest() {
        var config = LatticeConfiguration()
        config.cells[LatticeCellID(.orchestrator, .codebase).key] =
            LatticeCellSelection(id: LatticeCellID(.orchestrator, .codebase))
        let manifest = LatticeManifestBuilder.build(
            configuration: config,
            resolvedContexts: { _ in "" },
            draft: "task")!
        XCTAssertTrue(manifest.contains("coordination only"))
    }

    func testPlanOrdersRolesDeterministically() {
        var config = LatticeConfiguration()
        for pair in [(LatticeRole.tester, ContextLayer.tests),
                     (.planner, .codebase),
                     (.researcher, .documentation)] {
            config.cells[LatticeCellID(pair.0, pair.1).key] =
                LatticeCellSelection(id: LatticeCellID(pair.0, pair.1))
        }
        let plan = LatticeRunSnapshot.buildPlan(config)
        XCTAssertEqual(plan.map(\.role), [.researcher, .planner, .tester],
                       "worker order must be the documented deterministic order")
    }

    // MARK: Helpers

    private func configured() -> LatticeConfiguration {
        var config = LatticeConfiguration()
        let id = LatticeCellID(.builder, .codebase)
        config.cells[id.key] = LatticeCellSelection(id: id)
        return config
    }

    private func fits() -> LatticeTokenProjection {
        LatticeTokenProjection(
            promptTokens: 50, contextTokens: 200, reservedOutputTokens: 4_096,
            totalProjected: 4_346, contextWindow: 32_768, usableWindow: 28_672,
            remaining: 24_326, utilization: 4_346.0 / 28_672.0)
    }
}

// MARK: - B. Store integration (real workspace + fake engine)

@MainActor
final class IntentLatticeStoreTests: XCTestCase {

    private var appSupport: TempWorkspace!
    private var workspace: TempWorkspace!
    private var gitRepo: GitRepo!

    override func setUp() {
        appSupport = TempWorkspace()
        ModelStore.shared.overrideModelsDir = appSupport.url(for: "Models")
        SessionStore.shared.overrideSessionsDir = appSupport.url(for: "Sessions")
        IntentLatticeStore.overrideDraftsDir = appSupport.url(for: "Drafts")
        workspace = TempWorkspace()
        workspace.write("# Project docs", to: "README.md")
        workspace.makeDirectory("docs")
        workspace.makeDirectory("Tests")
        gitRepo = GitRepo(in: workspace)
        gitRepo.commitAll(message: "base")
    }

    override func tearDown() {
        IntentLatticeStore.overrideDraftsDir = nil
    }

    // MARK: Helpers

    private func makeStack() -> (AppState, IntentLatticeStore, FakeLLMEngine) {
        let engine = FakeLLMEngine()
        let appState = AppState(engine: EngineRouter(local: engine))
        let store = IntentLatticeStore()
        store.attach(controller: appState.sessions, appState: appState)
        return (appState, store, engine)
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Attach + open the git workspace; waits until availability reflects it.
    private func openWorkspace(_ appState: AppState, _ store: IntentLatticeStore) async {
        await appState.sessions.switchWorkspace(to: workspace.url)
        let ready = await waitUntil { store.availabilityInput.hasWorkspace }
        XCTAssertTrue(ready, "store must pick up the workspace change")
    }

    private func activateFirstModel(_ appState: AppState) -> CatalogModel {
        let model = ModelCatalog.all.first!
        appState.activeModelID = model.id
        appState.enginePhase = .ready(model.displayName)
        return model
    }

    // Scenario: availability driven by REAL application state

    func testAvailabilityReflectsRealWorkspace() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)

        XCTAssertEqual(store.availability(for: .codebase), .available)
        XCTAssertEqual(store.availability(for: .git), .available)
        XCTAssertEqual(store.availability(for: .documentation), .available)
        XCTAssertEqual(store.availability(for: .tests), .available)
        XCTAssertNotEqual(store.availability(for: .openFiles), .available,
                          "no files attached → openFiles must be unavailable")
    }

    func testNonGitWorkspaceMakesGitUnavailable() async {
        let plain = TempWorkspace()
        let (appState, store, engine) = makeStack()
        await appState.sessions.switchWorkspace(to: plain.url)
        let ready = await waitUntil { store.availabilityInput.hasWorkspace }
        XCTAssertTrue(ready)
        XCTAssertFalse(store.availabilityInput.isGitRepo)
        guard case .unavailable(let reason, _) = store.availability(for: .git) else {
            return XCTFail("git must be unavailable in a non-repo workspace")
        }
        XCTAssertTrue(reason.contains("not a git repository"))
    }

    // Scenario: unavailable cells cannot be selected

    func testToggleRejectsUnavailableCells() async {
        let (_, store, _) = makeStack()  // never attach a workspace
        store.toggle(LatticeCellID(.builder, .codebase))
        XCTAssertTrue(store.configuration.cells.isEmpty,
                      "selecting without a workspace must be impossible")
        store.select(LatticeCellID(.tester, .tests), source: .preset)
        XCTAssertTrue(store.configuration.cells.isEmpty)
    }

    // Scenarios: selection/deselection + weight changes + count

    func testSelectDeselectAndWeights() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)

        let id = LatticeCellID(.planner, .codebase)
        store.toggle(id)
        XCTAssertTrue(store.configuration.isSelected(id))
        XCTAssertEqual(store.selectedCellCount, 1)

        store.setWeight(id, 0.4)
        XCTAssertEqual(store.configuration.selection(for: id)?.weight, 0.4)
        store.setWeight(id, 9)
        XCTAssertEqual(store.configuration.selection(for: id)?.weight, 1.0, "weight clamps")

        store.setNote(id, "focus on parser")
        XCTAssertEqual(store.configuration.selection(for: id)?.note, "focus on parser")

        store.toggle(id)
        XCTAssertFalse(store.configuration.isSelected(id))
        XCTAssertEqual(store.selectedCellCount, 0)
    }

    // Scenario: suggestions never auto-activate; apply is explicit

    func testSuggestionsAppearButRequireExplicitApply() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)

        store.prompt = "fix the crash in the parser"
        let suggested = await waitUntil { !store.applicableSuggestions.isEmpty }
        XCTAssertTrue(suggested, "debug keywords must produce suggestions")
        XCTAssertTrue(store.configuration.cells.isEmpty,
                      "suggestions must never silently select cells")

        store.applySuggestions()
        XCTAssertFalse(store.configuration.cells.isEmpty)
        XCTAssertTrue(store.configuration.selections.allSatisfy { $0.source == .suggested })
        XCTAssertTrue(store.applicableSuggestions.isEmpty, "applied suggestions clear")
    }

    // Scenario: preset application through the store respects availability

    func testApplyPresetThroughStoreSkipsUnavailable() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        // No attached files → every Builder × Open Files cell must be skipped.
        store.applyPreset(LatticePresets.preset(id: "balanced-build")!)
        XCTAssertFalse(store.configuration.cells.isEmpty)
        XCTAssertTrue(store.presetSkips.contains { $0.cell.context == .openFiles })
        XCTAssertFalse(store.configuration.selections.contains { $0.id.context == .openFiles })
    }

    // Scenario: token projection is real, derived, labeled

    func testProjectionDerivesFromPromptAndSelections() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)

        store.prompt = String(repeating: "word ", count: 400)  // ~500 tokens
        store.select(LatticeCellID(.planner, .codebase))
        let proj = store.projection
        XCTAssertGreaterThan(proj.promptTokens, 0)
        XCTAssertGreaterThan(proj.contextTokens, 0, "selected context must add tokens")
        XCTAssertEqual(proj.reservedOutputTokens, store.reservedOutputTokens)
        XCTAssertEqual(proj.totalProjected,
                       proj.promptTokens + proj.contextTokens + proj.reservedOutputTokens)
        XCTAssertNotNil(proj.contextWindow, "active model → real window, not invented")
        XCTAssertNotNil(proj.utilization)
        XCTAssertGreaterThan(proj.utilization!, 0)
    }

    func testProjectionUsesEmDashSemanticsWithoutModel() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        // No model activated → window unknown → utilization must be nil (—).
        XCTAssertNil(store.projection.contextWindow)
        XCTAssertNil(store.projection.utilization)
    }

    // Scenarios: no-model / no-workspace validation + run eligibility

    func testValidationBlocksThenClearsAsStateChanges() async {
        let (appState, store, _) = makeStack()
        store.prompt = "implement feature"
        XCTAssertFalse(store.validation.canRun)
        XCTAssertEqual(store.validation.primaryBlocker, "Choose a model before running.")

        activateFirstModel(appState)
        store.prompt = "implement feature"  // trigger recompute with readiness
        XCTAssertFalse(store.validation.canRun)
        XCTAssertTrue(store.validation.blockers.contains { $0.contains("Open a workspace") })

        await openWorkspace(appState, store)
        // Opening a (fresh) workspace loads its draft — empty here, so the
        // prompt must be (re)entered after the switch, exactly like a user.
        store.prompt = "implement feature"
        XCTAssertFalse(store.validation.canRun)
        XCTAssertTrue(store.validation.blockers.contains { $0.contains("Apply a preset") })

        store.select(LatticeCellID(.builder, .codebase))
        XCTAssertTrue(store.validation.canRun, "all conditions met → eligible")
        XCTAssertTrue(store.validation.blockers.isEmpty)
    }

    // Scenario: run eligibility + immutable snapshot at commit

    func testCommitRunSendsGrantedOnlyManifestAndRuns() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)
        store.prompt = "implement feature"
        store.select(LatticeCellID(.builder, .codebase))
        XCTAssertTrue(store.validation.canRun)

        var delivered: String?
        let blocked = store.commitRun { manifest in
            delivered = manifest
            appState.sessions.send(manifest, attachments: [])
        }
        XCTAssertNil(blocked)
        XCTAssertNotNil(store.currentRun)
        XCTAssertEqual(store.phase, .running)
        let manifest = try! XCTUnwrap(delivered)
        XCTAssertTrue(manifest.contains("Builder"))
        XCTAssertTrue(manifest.contains("implement feature"))

        // Snapshot froze the prompt; editing the draft must not mutate it.
        let frozenPrompt = store.currentRun!.prompt
        store.prompt = "something else entirely"
        XCTAssertEqual(store.currentRun!.prompt, frozenPrompt)

        let finished = await waitUntil { appState.sessions.finishReason != nil }
        XCTAssertTrue(finished, "the real run must reach a terminal state")
    }

    func testCommitRunRefusesWhenInvalid() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        // No model, no prompt, no selection.
        var sent = false
        let reason = store.commitRun { _ in sent = true }
        XCTAssertNotNil(reason)
        XCTAssertFalse(sent, "blocked commit must never reach the runtime")
        XCTAssertEqual(reason, "Choose a model before running.")
    }

    // Scenario: cancel-state transitions

    func testCancelTransitionsThroughCancellingToFailed() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)
        store.prompt = "long task"
        store.select(LatticeCellID(.builder, .codebase))

        // Hold the generation so the run is observably live.
        engine.holdNextStream()
        engine.enqueue(.text("will be cancelled"))

        XCTAssertNil(store.commitRun { manifest in
            appState.sessions.send(manifest, attachments: [])
        })
        let running = await waitUntil { appState.sessions.isRunning }
        XCTAssertTrue(running, "the committed run must actually start")

        store.cancelRun()
        XCTAssertEqual(store.phase, .cancelling)
        let failed = await waitUntil { store.phase == .failed }
        XCTAssertTrue(failed, "cancel must land in the failed terminal state")
        XCTAssertTrue(store.stageStatus.values.allSatisfy { $0 == .skipped })
    }

    // Scenario: failed-run recovery — a failed run can be re-committed

    func testFailedRunRecovery() async {
        struct EngineBoom: Error {}
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)
        store.prompt = "doomed task"
        store.select(LatticeCellID(.builder, .codebase))

        engine.enqueue(.failure(EngineBoom()))
        XCTAssertNil(store.commitRun { manifest in
            appState.sessions.send(manifest, attachments: [])
        })
        let failed = await waitUntil { store.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(store.stageStatus.values.allSatisfy { $0 == .failed })

        // Recovery: re-commit with a working engine.
        engine.enqueue(.text("recovered"))
        XCTAssertNil(store.commitRun(sender: { manifest in
            appState.sessions.send(manifest, attachments: [])
        }), "a failed run must not permanently block new runs")
        let completed = await waitUntil { store.phase == .completed }
        XCTAssertTrue(completed)
        XCTAssertTrue(store.stageStatus.values.allSatisfy { $0 == .completed })
    }

    // Scenario: collapse preserves draft state

    func testCollapsePreservesEverything() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        store.prompt = "survive collapse"
        store.select(LatticeCellID(.reviewer, .git))
        store.setWeight(LatticeCellID(.reviewer, .git), 0.6)
        store.activeView = .plan

        store.isExpanded = false
        XCTAssertEqual(store.prompt, "survive collapse")
        XCTAssertEqual(store.configuration.selection(for: LatticeCellID(.reviewer, .git))?.weight, 0.6)
        XCTAssertEqual(store.activeView, .plan)
        XCTAssertTrue(store.collapsedSummary.contains("1 role"))

        store.isExpanded = true
        XCTAssertTrue(store.configuration.isSelected(LatticeCellID(.reviewer, .git)))
    }

    // Scenario: session restoration — a fresh store rehydrates the draft

    func testDraftPersistsPerWorkspaceAndRestores() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        store.prompt = "persisted task"
        store.select(LatticeCellID(.planner, .documentation))
        store.isExpanded = false

        // Persistence is debounced (400 ms) — poll for the draft file.
        let draftsDir = IntentLatticeStore.overrideDraftsDir!
            .appendingPathComponent("LatticeDrafts")
        let written = await waitUntil(timeout: 8) {
            ((try? FileManager.default.contentsOfDirectory(
                at: draftsDir, includingPropertiesForKeys: nil)) ?? []).isEmpty == false
        }
        XCTAssertTrue(written, "draft must persist to disk")

        // Simulate relaunch: brand-new store attached to the same workspace.
        let store2 = IntentLatticeStore()
        store2.attach(controller: appState.sessions, appState: appState)
        let restored = await waitUntil { store2.prompt == "persisted task" }
        XCTAssertTrue(restored, "fresh store must restore the persisted draft")
        XCTAssertTrue(store2.configuration.isSelected(LatticeCellID(.planner, .documentation)))
        XCTAssertFalse(store2.isExpanded)
        XCTAssertNil(store2.currentRun, "a restored draft must never resurrect a run")
    }

    // Scenario: superposition capability gate (Option B — honest)

    func testSuperpositionIsCapabilityGated() {
        XCTAssertFalse(IntentLatticeStore.superpositionSupported)
        XCTAssertFalse(IntentLatticeStore.superpositionExplanation.isEmpty)
        XCTAssertTrue(IntentLatticeStore.superpositionExplanation.contains("not available"))
    }
}
