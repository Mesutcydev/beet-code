import XCTest
@testable import BeetCode

/// End-to-end harness: AppState → model manager (local fixture downloads) →
/// controller → AgentLoop, driven by the fake engine. No network, no weights,
/// no Metal.
@MainActor
final class EndToEndTests: XCTestCase {

    private var appSupport: TempWorkspace!

    override func setUpWithError() throws {
        // Isolate persistence from the developer's real Application Support.
        appSupport = TempWorkspace()
        ModelStore.shared.overrideModelsDir = appSupport.url(for: "Models")
        SessionStore.shared.overrideSessionsDir = appSupport.url(for: "Sessions")
        TaskCapsuleStore.shared.overrideDirectory = appSupport.url(for: "Capsules")
        RepoSummaryCache.shared.overrideDirectory = appSupport.url(for: "Summaries")
        // Restore any previous launch state that could interfere.
        var preferences = AppPreferencesStore.shared.current
        preferences.lastWorkspacePath = nil
        preferences.lastModelID = nil
        preferences.lastSessionID = nil
        preferences.autoResumeDownloads = false
        AppPreferencesStore.shared.save(preferences)
    }

    func testDownloadFinalizeActivateThenAgentRun() async throws {
        // 1. A local fixture “model” on disk (two files).
        let fixture = TempWorkspace()
        fixture.write("fake weights v1", to: "model.safetensors")
        fixture.write("{\"arch\": \"test\"}", to: "config.json")

        let engine = FakeLLMEngine()
        let appState = AppState(
            engine: EngineRouter(local: engine),
            hub: FixtureHub(directory: fixture.url))

        // 2. A git workspace for the agent.
        let repo = TempWorkspace()
        repo.write("base", to: "base.txt")
        let git = GitRepo(in: repo)
        git.commitAll(message: "base")
        await appState.sessions.switchWorkspace(to: repo.url)

        // 3. Download a catalog model through the full pipeline.
        let model = try XCTUnwrap(ModelCatalog.all.first)
        appState.startDownload(of: model)

        // Completion → registration only. Downloading must NOT auto-activate:
        // loading is an explicit user decision, so a background download can
        // never switch engines under a running agent.
        let deadline = Date().addingTimeInterval(20)
        while appState.modelStore.installedModel(id: model.id) == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let downloadState = appState.downloadManager.state(for: model.id)
        XCTAssertNotNil(
            appState.modelStore.installedModel(id: model.id),
            "download did not finalize (manager state: \(downloadState))")
        XCTAssertNotEqual(
            appState.enginePhase, .ready(model.displayName),
            "a completed download must not auto-load the model")
        XCTAssertNil(appState.activeModelID, "no model may be active from a download alone")

        // 4. Explicitly load, then run an agent task on the loaded engine.
        await appState.activate(model: model)
        XCTAssertEqual(appState.enginePhase, .ready(model.displayName))
        XCTAssertEqual(appState.activeModelID, model.id)
        engine.enqueue(.text("All done here."))
        appState.sessions.send("inspect the repo")
        let finishDeadline = Date().addingTimeInterval(15)
        while appState.sessions.finishReason == nil, Date() < finishDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(appState.sessions.finishReason, .completed("All done here."))
    }

    func testPausedDownloadManifestSurvivesRelaunch() async throws {
        // A fixture large enough that the transfer takes well over a second.
        let fixture = TempWorkspace()
        let bigFile = fixture.url(for: "weights.bin")
        try FileManager.default.createDirectory(
            at: bigFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bigFile.path, contents: nil)
        let chunk = Data(repeating: 0x61, count: 1_048_576)  // 1 MiB
        let handle = try FileHandle(forWritingTo: bigFile)
        for _ in 0..<256 { try handle.write(contentsOf: chunk) }  // 256 MiB
        try handle.close()

        let model = try XCTUnwrap(ModelCatalog.all.first)
        let manager = ModelDownloadManager(
            tokenProvider: { nil },
            hub: FixtureHub(directory: fixture.url))
        manager.start(model: model, into: appSupport.url(for: "dl"))
        XCTAssertTrue(manager.hasInterruptedDownload(modelID: model.id), "manifest written on start")

        // Pause mid-transfer; poll until the orchestrator settles.
        try? await Task.sleep(for: .milliseconds(400))
        manager.pause(modelID: model.id)
        let pauseDeadline = Date().addingTimeInterval(10)
        var settled = false
        while Date() < pauseDeadline {
            if case .paused = manager.state(for: model.id) { settled = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(settled, "download did not settle into paused (state: \(manager.state(for: model.id)))")

        // A fresh manager (simulated relaunch) must see the paused state
        // from the persisted manifest.
        let relaunched = ModelDownloadManager(
            tokenProvider: { nil },
            hub: FixtureHub(directory: fixture.url))
        guard case .paused(let progress) = relaunched.state(for: model.id) else {
            return XCTFail("paused state did not survive relaunch: \(relaunched.state(for: model.id))")
        }
        XCTAssertGreaterThan(progress.totalBytes, 0)

        // Resume on the relaunched manager actually completes the download.
        let modelCatalog = try XCTUnwrap(ModelCatalog.model(id: model.id))
        relaunched.start(model: modelCatalog, into: appSupport.url(for: "dl"))
        let resumeDeadline = Date().addingTimeInterval(60)
        var completed = false
        while Date() < resumeDeadline {
            if case .completed = relaunched.state(for: model.id) { completed = true; break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(completed, "resume did not complete: \(relaunched.state(for: model.id))")
        XCTAssertFalse(relaunched.hasInterruptedDownload(modelID: model.id), "completion must clear the manifest")
    }
    func testCheckpointUndoFromSidebarControl() async throws {
        let repo = TempWorkspace()
        repo.write("original", to: "file.txt")
        let git = GitRepo(in: repo)
        git.commitAll(message: "base")

        let engine = FakeLLMEngine()
        let appState = AppState(engine: EngineRouter(local: engine))
        await appState.sessions.switchWorkspace(to: repo.url)

        // Run a task that edits through approval (read first — the agent
        // must read a file before editing it).
        engine.enqueue(texts: [
            "```tool\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"file.txt\"}}\n```",
            "```tool\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"file.txt\", \"content\": \"agent change\"}}\n```",
            "Changed it.",
        ])
        appState.sessions.send("change file.txt")
        let approvalDeadline = Date().addingTimeInterval(10)
        while appState.sessions.pendingApproval == nil, Date() < approvalDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let request = appState.sessions.pendingApproval else {
            return XCTFail("expected approval request")
        }
        appState.sessions.approve(true)
        let finishDeadline = Date().addingTimeInterval(15)
        while appState.sessions.finishReason == nil, Date() < finishDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(appState.sessions.finishReason, .completed("Changed it."))
        XCTAssertEqual(repo.read("file.txt"), "agent change")

        // Undo via the sidebar control: restores the checkpoint.
        appState.sessions.undoLastCheckpoint()
        XCTAssertEqual(repo.read("file.txt"), "original")
    }
}