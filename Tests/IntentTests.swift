import XCTest
@testable import BeetCode

/// Tests for the Intent system that replaced the Intent Lattice:
/// roles + focus chips composed into an auditable preface, honest token
/// telemetry, and the composer store's availability/validation/send logic.
///
/// Two layers:
///   A. Pure logic (IntentComposer, IntentTokens, presets, resolvers) — no
///      app objects.
///   B. Store integration — real temp git workspace, FakeLLMEngine, no
///      network, no weights, no Metal.

// MARK: - A. Pure logic

final class IntentComposerTests: XCTestCase {

    func testEmptySelectionLeavesDraftUntouched() {
        let selection = IntentSelection()
        let composed = IntentComposer.compose(selection: selection, draft: "just do it") { _ in "ignored" }
        XCTAssertEqual(composed, "just do it")
    }

    func testRolesRenderInFixedPipelineOrderRegardlessOfSelectionOrder() {
        var selection = IntentSelection()
        selection.roles = [.verify, .research, .build] // tap order scrambled
        let composed = IntentComposer.compose(selection: selection, draft: "task") { _ in "" }

        let research = composed.range(of: "- Research:")
        let build = composed.range(of: "- Build:")
        let verify = composed.range(of: "- Verify:")
        XCTAssertNotNil(research); XCTAssertNotNil(build); XCTAssertNotNil(verify)
        XCTAssertTrue(research!.lowerBound < build!.lowerBound, "research precedes build")
        XCTAssertTrue(build!.lowerBound < verify!.lowerBound, "build precedes verify")
        XCTAssertFalse(composed.contains("Review:"), "unselected roles never appear")
    }

    func testRoleDedupIsStructural() {
        var selection = IntentSelection()
        selection.roles.insert(.build)
        selection.roles.insert(.build)
        let composed = IntentComposer.compose(selection: selection, draft: "task") { _ in "" }
        XCTAssertEqual(composed.components(separatedBy: "- Build:").count - 1, 1,
                       "a role can never be injected twice")
    }

    func testNoInventedFencesOrWeightMetadata() {
        var selection = IntentSelection()
        selection.roles = [.build, .review]
        let composed = IntentComposer.compose(selection: selection, draft: "task") { _ in "" }
        XCTAssertFalse(composed.contains("[lattice]"))
        XCTAssertFalse(composed.contains("###"))
        XCTAssertFalse(composed.lowercased().contains("weight"))
        XCTAssertTrue(composed.hasPrefix("Intent for this turn:"))
    }

    func testEmptyFocusResolverIsHonest() {
        var selection = IntentSelection()
        selection.focus = [.docs]
        let composed = IntentComposer.compose(selection: selection, draft: "task") { _ in "" }
        XCTAssertTrue(composed.contains("- @docs — (nothing found)."),
                      "empty resolution must be marked, never fabricated")
        XCTAssertFalse(composed.contains("appended below"))
    }

    func testResolvedFocusAppendsContentAfterPreambleBeforeDraft() {
        var selection = IntentSelection()
        selection.focus = [.git]
        let composed = IntentComposer.compose(selection: selection, draft: "the draft") { source in
            source == .git ? "branch: main\n M App.swift" : ""
        }
        XCTAssertTrue(composed.contains("- @git — current branch and uncommitted diff appended below."))
        let focus = composed.range(of: "Focus:")!
        let content = composed.range(of: "branch: main")!
        let draft = composed.range(of: "the draft")!
        XCTAssertTrue(focus.lowerBound < content.lowerBound, "resolved content follows the preamble")
        XCTAssertTrue(content.lowerBound < draft.lowerBound, "the draft comes last")
    }

    func testFilesFocusListsNamesInlineWithoutAppendedBlock() {
        var selection = IntentSelection()
        selection.focus = [.files]
        let composed = IntentComposer.compose(selection: selection, draft: "task") { source in
            source == .files ? "Foo.swift, Bar.swift" : ""
        }
        XCTAssertTrue(composed.contains("- @files — attached files are quoted with this message: Foo.swift, Bar.swift."))
        // Names appear exactly once — no duplicated appended block.
        XCTAssertEqual(composed.components(separatedBy: "Foo.swift").count - 1, 1)
    }

    func testFocusContentRendersInFixedOrder() {
        var selection = IntentSelection()
        selection.focus = [.codebase, .git] // scrambled tap order
        let composed = IntentComposer.compose(selection: selection, draft: "task") { source in
            "content-\(source.rawValue)"
        }
        let git = composed.range(of: "content-git")!
        let codebase = composed.range(of: "content-codebase")!
        XCTAssertTrue(git.lowerBound < codebase.lowerBound, "git precedes codebase in fixed order")
    }

    func testDraftOnlySuffix() {
        var selection = IntentSelection()
        selection.roles = [.build]
        let composed = IntentComposer.compose(selection: selection, draft: "do the thing") { _ in "" }
        XCTAssertTrue(composed.hasSuffix("do the thing"))
    }
}

final class IntentTokenTests: XCTestCase {

    func testEstimateIsPlainCharsOverFour() {
        XCTAssertEqual(IntentTokens.estimate(""), 0)
        XCTAssertEqual(IntentTokens.estimate("abcd"), 1)
        XCTAssertEqual(IntentTokens.estimate("abcde"), 2)
        XCTAssertEqual(IntentTokens.estimate(String(repeating: "x", count: 400)), 100)
    }
}

final class IntentPresetTests: XCTestCase {

    func testPresetCurations() {
        XCTAssertEqual(Set(IntentPresets.preset(id: "research-first")!.roles), [.research])
        XCTAssertEqual(Set(IntentPresets.preset(id: "ship-it")!.roles), [.build, .verify])
        XCTAssertEqual(Set(IntentPresets.preset(id: "test-verify")!.roles), [.verify, .review])
        XCTAssertEqual(Set(IntentPresets.preset(id: "full-pipeline")!.roles),
                       [.research, .build, .review, .verify])
        // Presets are role-only: no preset may smuggle in focus sources.
        XCTAssertEqual(IntentPresets.all.count, 4)
    }
}

final class IntentContextResolverTests: XCTestCase {

    func testCodebaseContextMapsTopLevelStructure() {
        let workspace = TempWorkspace()
        defer { _ = workspace } // keep alive until the end of the test
        workspace.write("x", to: "Package.swift")
        workspace.makeDirectory("Sources")
        workspace.makeDirectory("node_modules") // must be excluded

        let map = ContextResolvers.codebaseContext(workspace: workspace.url)
        XCTAssertTrue(map.contains("Sources/"))
        XCTAssertTrue(map.contains("Package.swift"))
        XCTAssertFalse(map.contains("node_modules"), "vendor directories are excluded")
    }

    func testDocumentationContextFindsRootAndDocsMarkdown() {
        let workspace = TempWorkspace()
        defer { _ = workspace }
        workspace.write("# hi", to: "README.md")
        workspace.write("# guide", to: "docs/GUIDE.md")

        let docs = ContextResolvers.documentationContext(workspace: workspace.url)
        XCTAssertTrue(docs.contains("README.md"))
        XCTAssertTrue(docs.contains("GUIDE.md"))
    }

    func testDocumentationContextEmptyWithoutDocs() {
        let workspace = TempWorkspace()
        defer { _ = workspace }
        XCTAssertEqual(ContextResolvers.documentationContext(workspace: workspace.url), "")
    }

    func testGitContextEmptyOutsideRepoAndPresentInside() {
        let plain = TempWorkspace()
        defer { _ = plain }
        XCTAssertEqual(ContextResolvers.gitContext(workspace: plain.url), "")

        let repo = TempWorkspace()
        defer { _ = repo }
        repo.write("# repo", to: "README.md")
        let git = GitRepo(in: repo)
        git.commitAll(message: "base")
        let context = ContextResolvers.gitContext(workspace: repo.url)
        XCTAssertTrue(context.contains("branch:"))
    }
}

// MARK: - B. Store integration (real workspace + fake engine)

@MainActor
final class ComposerStoreTests: XCTestCase {

    private var appSupport: TempWorkspace!
    private var workspace: TempWorkspace!
    private var gitRepo: GitRepo!

    override func setUp() {
        appSupport = TempWorkspace()
        ModelStore.shared.overrideModelsDir = appSupport.url(for: "Models")
        SessionStore.shared.overrideSessionsDir = appSupport.url(for: "Sessions")
        ComposerStore.overrideDraftsDir = appSupport.url(for: "Drafts")
        workspace = TempWorkspace()
        workspace.write("# Project docs", to: "README.md")
        workspace.makeDirectory("docs")
        workspace.makeDirectory("Tests")
        workspace.makeDirectory("Sources")
        gitRepo = GitRepo(in: workspace)
        gitRepo.commitAll(message: "base")
    }

    override func tearDown() {
        ComposerStore.overrideDraftsDir = nil
        ModelStore.shared.overrideModelsDir = nil
        SessionStore.shared.overrideSessionsDir = nil
    }

    // MARK: Helpers

    private func makeStack() -> (AppState, ComposerStore, FakeLLMEngine) {
        let engine = FakeLLMEngine()
        let appState = AppState(engine: EngineRouter(local: engine))
        let store = ComposerStore()
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

    /// Open the git workspace; waits until the store's availability reflects it.
    private func openWorkspace(_ appState: AppState, _ store: ComposerStore) async {
        await appState.sessions.switchWorkspace(to: workspace.url)
        let ready = await waitUntil { store.availability(for: .git).isAvailable }
        XCTAssertTrue(ready, "store must pick up the workspace change")
    }

    private func activateFirstModel(_ appState: AppState) -> CatalogModel {
        let model = ModelCatalog.all.first!
        appState.activeModelID = model.id
        appState.enginePhase = .ready(model.displayName)
        return model
    }

    // MARK: Availability

    func testAvailabilityReflectsRealWorkspace() async {
        let (appState, store, _) = makeStack()
        await openWorkspace(appState, store)

        XCTAssertTrue(store.availability(for: .git).isAvailable)
        XCTAssertTrue(store.availability(for: .docs).isAvailable)
        XCTAssertTrue(store.availability(for: .codebase).isAvailable)
        guard case .unavailable = store.availability(for: .files) else {
            return XCTFail("@files must be unavailable until a file is attached")
        }

        store.attachments = [ComposerAttachment(url: workspace.url(for: "README.md"))]
        XCTAssertTrue(store.availability(for: .files).isAvailable,
                      "attaching a file grants @files")
    }

    func testNonGitWorkspaceMakesGitUnavailable() async {
        let plain = TempWorkspace()
        let (appState, store, _) = makeStack()
        await appState.sessions.switchWorkspace(to: plain.url)
        let ready = await waitUntil { store.availability(for: .codebase).isAvailable }
        XCTAssertTrue(ready)
        guard case .unavailable(let reason) = store.availability(for: .git) else {
            return XCTFail("git must be unavailable in a non-repo workspace")
        }
        XCTAssertTrue(reason.contains("not a git repository"))
    }

    func testFocusToggleRejectsUnavailableSources() {
        let (_, store, _) = makeStack() // no workspace attached
        store.toggleFocus(.git)
        store.toggleFocus(.codebase)
        XCTAssertTrue(store.selection.focus.isEmpty,
                      "unavailable sources can never be selected")
    }

    // MARK: Selection semantics

    func testRolesAreBinaryAndPresetsReplace() {
        let (_, store, _) = makeStack()
        store.toggleRole(.build)
        store.toggleRole(.build)
        XCTAssertEqual(store.selection.roles, [], "second tap deselects")

        store.applyPreset(IntentPresets.preset(id: "ship-it")!)
        XCTAssertEqual(store.selection.roles, [.build, .verify])
        store.applyPreset(IntentPresets.preset(id: "research-first")!)
        XCTAssertEqual(store.selection.roles, [.research], "presets replace, never accumulate")
        store.clearIntent()
        XCTAssertTrue(store.selection.isEmpty)
    }

    // MARK: Estimate

    func testEstimateGrowsWithDraftAndSelection() async {
        let (appState, store, _) = makeStack()
        await openWorkspace(appState, store)

        XCTAssertEqual(store.estimate.totalTokens, 0)
        store.prompt = String(repeating: "x", count: 400)
        let draftOnly = store.estimate.totalTokens
        XCTAssertEqual(draftOnly, 100)

        store.toggleRole(.build)
        XCTAssertGreaterThan(store.estimate.totalTokens, draftOnly,
                             "a selected role adds its instruction tokens")

        store.toggleFocus(.git)
        let withGit = store.estimate.totalTokens
        XCTAssertGreaterThan(withGit, draftOnly, "resolved focus content is counted")
        XCTAssertEqual(store.estimate.focusTokens,
                       IntentTokens.estimate(store.resolvedFocusCache[.git] ?? ""))
    }

    func testUtilizationUnknownWithoutLocalModel() async {
        let (appState, store, _) = makeStack()
        await openWorkspace(appState, store)
        store.prompt = "hello"
        XCTAssertNil(store.estimate.contextWindow)
        XCTAssertNil(store.estimate.utilization,
                     "no percentage against an unknown window — absolute tokens only")

        activateFirstModel(appState)
        store.prompt = "hello!" // trigger a recompute against the new window
        let saw = await waitUntil { store.estimate.utilization != nil }
        XCTAssertTrue(saw, "a loaded local model supplies the real window")
        XCTAssertEqual(store.estimate.contextWindow, ModelCatalog.all.first!.contextWindow)
    }

    // MARK: Validation + send

    func testSendBlockedWithoutWorkspaceOrModel() async {
        let (appState, store, _) = makeStack()
        store.prompt = "do work"
        XCTAssertEqual(store.sendBlocker, "Open a project folder first")
        XCTAssertFalse(store.send())
        XCTAssertEqual(store.prompt, "do work", "a blocked send keeps the draft")

        await openWorkspace(appState, store)
        XCTAssertEqual(store.sendBlocker, "Choose a model to run")
        XCTAssertFalse(store.send())

        activateFirstModel(appState)
        // Opening a workspace loads its draft (empty here), so the prompt is
        // (re)entered after the switch — exactly like a user.
        store.prompt = "do work"
        XCTAssertNil(store.sendBlocker)
        XCTAssertTrue(store.canSend)
    }

    func testSendComposesIntentAndDispatchesOneShot() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)
        engine.enqueue(.text("done"))

        store.prompt = "implement the feature"
        store.toggleRole(.build)
        store.toggleRole(.verify)
        store.toggleFocus(.git)

        XCTAssertTrue(store.send(), "valid composer state must dispatch")

        // One-shot semantics: everything clears after dispatch.
        XCTAssertEqual(store.prompt, "")
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)

        // The transcript carries the composed message: fixed role order,
        // focus line, draft last.
        let delivered = await waitUntil {
            appState.sessions.transcript.contains {
                if case .user(let text) = $0.kind {
                    return text.contains("Intent for this turn:") && text.contains("implement the feature")
                }
                return false
            }
        }
        XCTAssertTrue(delivered, "the composed intent must reach the transcript")

        let text = appState.sessions.transcript.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text }
            return nil
        }.first!
        XCTAssertTrue(text.contains("- Build:"))
        XCTAssertTrue(text.contains("- Verify:"))
        XCTAssertTrue(text.contains("- @git — current branch and uncommitted diff appended below."))
        XCTAssertTrue(text.contains("branch:"), "real git content was resolved at send time")
        XCTAssertTrue(text.hasSuffix("implement the feature"))

        let finished = await waitUntil { appState.sessions.finishReason != nil }
        XCTAssertTrue(finished, "the real run must reach a terminal state")
    }

    func testSendWithoutIntentLeavesMessageUntouched() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        activateFirstModel(appState)
        engine.enqueue(.text("done"))

        store.prompt = "plain question"
        XCTAssertTrue(store.send())
        let delivered = await waitUntil {
            appState.sessions.transcript.contains {
                if case .user(let text) = $0.kind { return text == "plain question" }
                return false
            }
        }
        XCTAssertTrue(delivered, "no selection → the draft is sent verbatim")
    }

    func testSlashCommandsBypassValidationAndNeverSend() async {
        let (appState, store, engine) = makeStack()
        await openWorkspace(appState, store)
        // No model active — slash commands must still run locally.
        store.prompt = "/help"
        XCTAssertTrue(store.send())
        XCTAssertEqual(store.prompt, "")
        let noticed = await waitUntil {
            appState.sessions.transcript.contains {
                if case .notice = $0.kind { return true }
                return false
            }
        }
        XCTAssertTrue(noticed, "/help posts a local notice")
        XCTAssertFalse(appState.sessions.transcript.contains {
            if case .user(let text) = $0.kind { return text == "/help" }
            return false
        }, "slash commands are never sent to the model")
    }

    // MARK: Persistence

    func testDraftPersistsPerWorkspace() async {
        let (appState, store, _) = makeStack()
        await openWorkspace(appState, store)
        store.prompt = "draft for this project"
        store.toggleRole(.verify)
        store.toggleFocus(.docs)

        // Draft persistence is debounced; wait for the file to land.
        let draftsDir = appSupport.url(for: "Drafts/ComposerDrafts")
        let persisted = await waitUntil {
            (try? FileManager.default.contentsOfDirectory(atPath: draftsDir.path).isEmpty) == false
        }
        XCTAssertTrue(persisted, "the draft must be persisted")

        // A fresh store attached to the same workspace restores the draft.
        let restored = ComposerStore()
        restored.attach(controller: appState.sessions, appState: appState)
        XCTAssertEqual(restored.prompt, "draft for this project")
        XCTAssertEqual(restored.selection.roles, [.verify])
        XCTAssertEqual(restored.selection.focus, [.docs])
    }

    func testSwitchingWorkspaceLoadsThatWorkspacesDraft() async {
        let (appState, store, _) = makeStack()
        await openWorkspace(appState, store)
        store.prompt = "workspace A draft"
        let persisted = await waitUntil {
            (try? FileManager.default.contentsOfDirectory(
                atPath: appSupport.url(for: "Drafts/ComposerDrafts").path).isEmpty) == false
        }
        XCTAssertTrue(persisted)

        let other = TempWorkspace()
        other.write("x", to: "README.md") // an empty tree cannot be committed
        _ = GitRepo(in: other).commitAll(message: "base")
        await appState.sessions.switchWorkspace(to: other.url)
        let switched = await waitUntil { store.prompt.isEmpty }
        XCTAssertTrue(switched, "a fresh workspace starts with an empty draft")

        await appState.sessions.switchWorkspace(to: workspace.url)
        let restored = await waitUntil { store.prompt == "workspace A draft" }
        XCTAssertTrue(restored, "switching back restores workspace A's draft")
    }
}
