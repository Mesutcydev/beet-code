import XCTest
@testable import BeetCode

/// Vision sidecar (SmolVLM2) integration: catalog shape, tolerant decoding,
/// and provider routing. Hermetic — the local describe seam is stubbed, no
/// MLX, no network, no Keychain.
final class VisionTests: XCTestCase {

    // MARK: Catalog

    func testBundledVisionEntriesAreWellFormed() {
        let vision = ModelCatalog.bundled.filter { $0.role == .vision }
        XCTAssertEqual(vision.count, 2, "SmolVLM2 500M + 2.2B sidecars are curated")
        for model in vision {
            XCTAssertEqual(model.family, "SmolVLM2")
            XCTAssertEqual(model.format, .mlx, "\(model.id): sidecars run in-process via MLXVLM")
            XCTAssertTrue(model.repo.contains("SmolVLM2"), "\(model.id): repo should point at a SmolVLM2 build")
            XCTAssertGreaterThan(model.diskBytes, 0)
        }
    }

    func testChatIsTheDefaultRole() {
        let chat = ModelCatalog.bundled.filter { $0.role == .chat }
        XCTAssertEqual(chat.count, ModelCatalog.bundled.count - 2)
    }

    // MARK: Tolerant decoding

    func testCatalogDecodesWithoutFormatAndRoleKeys() throws {
        // Shape written by builds predating the format/role fields.
        let json = """
            [{"id":"old","repo":"a/b","displayName":"Old","family":"Qwen3",
              "parameters":"1B","quantization":"4-bit","diskBytes":1000,
              "contextWindow":32768,"minRAMGB":6,"recommendedRAMGB":8,
              "notes":"legacy"}]
            """
        let models = try JSONDecoder().decode([CatalogModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].format, .mlx)
        XCTAssertEqual(models[0].role, .chat)
    }

    func testVisionRoleRoundTrips() throws {
        let model = CatalogModel(
            id: "v", repo: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            displayName: "V", family: "SmolVLM2", parameters: "500M",
            quantization: "bf16", diskBytes: 1, contextWindow: 16_384,
            minRAMGB: 4, recommendedRAMGB: 6, notes: "", role: .vision)
        let data = try JSONEncoder().encode([model])
        let decoded = try JSONDecoder().decode([CatalogModel].self, from: data)
        XCTAssertEqual(decoded.first?.role, .vision)
    }

    // MARK: Picker

    func testPickerPrefersLargerInstalledSidecar() {
        let catalog = ModelCatalog.bundled
        // Only the 500M installed → picked.
        XCTAssertEqual(
            VisionProvider.pickVisionModel(from: catalog, isInstalled: { $0 == "smolvlm2-500m-mlx" })?.id,
            "smolvlm2-500m-mlx")
        // Both installed → the 2.2B wins (quality).
        XCTAssertEqual(
            VisionProvider.pickVisionModel(from: catalog, isInstalled: { _ in true })?.id,
            "smolvlm2-2.2b-mlx")
        // None installed → nil.
        XCTAssertNil(VisionProvider.pickVisionModel(from: catalog, isInstalled: { _ in false }))
        // Chat models are never picked, even when installed.
        XCTAssertNil(VisionProvider.pickVisionModel(from: catalog, isInstalled: { $0 == "qwen3-4b-4bit" }))
    }

    // MARK: Routing

    func testDescribePrefersLocalSidecar() async throws {
        let resolution = VisionProvider.LocalResolution(
            model: ModelCatalog.bundled.first { $0.role == .vision }!,
            directory: URL(fileURLWithPath: "/tmp/unused"),
            diskBytes: 1)
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = { resolution }
        VisionProvider.localDescribe = { _, _, _ in "local description" }

        let result = try await VisionProvider.describe(
            imageAt: URL(fileURLWithPath: "/tmp/unused.png"), prompt: "p")
        XCTAssertEqual(result, "local description")
    }

    func testLocalFailureFallsThroughToBYOK() async throws {
        struct Probe: Error {}
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = {
            VisionProvider.LocalResolution(
                model: ModelCatalog.bundled.first { $0.role == .vision }!,
                directory: URL(fileURLWithPath: "/tmp/unused"),
                diskBytes: 1)
        }
        VisionProvider.localDescribe = { _, _, _ in throw Probe() }

        // No BYOK keys in the test host → the failure surfaces as
        // noProvider, proving the local error didn't escape directly.
        do {
            _ = try await VisionProvider.describe(
                imageAt: URL(fileURLWithPath: "/tmp/unused.png"), prompt: "p")
            // A host WITH a vision BYOK key would take the network path
            // instead — acceptable: the fall-through is what we assert.
        } catch let error as VisionProvider.VisionError {
            guard case .noProvider = error else {
                return XCTFail("expected noProvider, got \(error)")
            }
        }
    }

    func testNoProviderErrorMentionsSmolVLM2() {
        let message = VisionProvider.VisionError.noProvider.errorDescription ?? ""
        XCTAssertTrue(message.contains("SmolVLM2"))
        XCTAssertTrue(message.contains("Model Manager"))
    }

    // MARK: Live smoke (opt-in)

    /// Real end-to-end proof: loads the actual SmolVLM2 weights through
    /// VisionEngine and describes an image. Opt-in (touch
    /// /tmp/beetcode-vlm-smoke — xcodebuild doesn't reliably forward env
    /// vars to the test host) because it needs a downloaded model and
    /// touches MLX — the regular suite stays hermetic.
    func testLiveSmolVLM2Describe() async throws {
        let flag = "/tmp/beetcode-vlm-smoke"
        guard FileManager.default.fileExists(atPath: flag) else { return }
        let model = ModelCatalog.bundled.first { $0.id == "smolvlm2-500m-mlx" }!
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Models/smolvlm2-500m-mlx", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path) else {
            XCTFail("SmolVLM2-500M not downloaded to \(dir.path)")
            return
        }
        let image = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["BEETCODE_VLM_IMAGE"]
                ?? "/Users/m/Downloads/new project/menu-screenshot.png")
        let result = try await VisionEngine.shared.describe(
            imageAt: image,
            prompt: "Describe this image concisely for a coding agent.",
            model: model,
            directory: dir,
            diskBytes: model.diskBytes)
        print("SMOLVLM2_SAYS: \(result)")
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}


// MARK: - Vision inside a real agent session

/// describe_image executing inside an AgentLoop run: the loop resolves the
/// call through the (stubbed) provider and the answer flows back as a tool
/// observation. Same harness as AgentLoopTests — FakeLLMEngine, temp
/// workspace, no MLX, no network, no Keychain.
final class VisionSessionTests: XCTestCase {

    private var workspace: TempWorkspace!
    private var engine: FakeLLMEngine!
    /// Three backticks (built without literal backticks in source).
    private let fence = "\u{60}\u{60}\u{60}"

    override func setUpWithError() throws {
        workspace = TempWorkspace()
        engine = FakeLLMEngine()
        TaskCapsuleStore.shared.overrideDirectory = workspace.url(for: "Capsules")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        workspace = nil
        engine = nil
    }

    private func toolCall(_ name: String, _ arguments: String) -> String {
        "\(fence)tool\n{\"name\": \"\(name)\", \"arguments\": \(arguments)}\n\(fence)"
    }

    private func makeVisionLoop() -> AgentLoop {
        let permissions = PermissionGate(
            autoApproveEdits: false,
            autoApproveCommands: false,
            workspace: workspace.workspace)
        return AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), DescribeImageTool()],
            permissions: permissions,
            configuration: AgentLoop.Configuration())
    }

    private func toolResults(_ collector: EventCollector) -> [(name: String, output: String, failed: Bool)] {
        collector.events { event in
            if case .toolCallFinished(let invocation, let output, let failed) = event {
                return (invocation.name, output, failed)
            }
            return nil
        }
    }

    func testDescribeImageExecutesInsideAgentSession() async throws {
        workspace.write("fake-png-bytes", to: "menu.png")
        let resolution = VisionProvider.LocalResolution(
            model: ModelCatalog.bundled.first { $0.role == .vision }!,
            directory: URL(fileURLWithPath: "/tmp/unused"),
            diskBytes: 1)
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = { resolution }
        VisionProvider.localDescribe = { _, _, _ in "a menu bar with three icons" }

        engine.enqueue(texts: [
            "Checking the screenshot.\n"
                + toolCall("describe_image", #"{"path": "menu.png", "prompt": "what is on screen"}"#),
            "The screenshot shows a menu bar with three icons. Task complete.",
        ])
        let loop = makeVisionLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "what does the menu show?")
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: 10)
        _ = await collection

        XCTAssertNotNil(finish, "loop never finished")
        XCTAssertEqual(collector.toolCalls().map(\.name), ["describe_image"])
        XCTAssertTrue(collector.approvals().isEmpty, "image describes are reads — never gated")
        let results = toolResults(collector)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.output, "a menu bar with three icons")
        XCTAssertEqual(results.first?.failed, false)
        XCTAssertEqual(
            collector.finish,
            .completed("The screenshot shows a menu bar with three icons. Task complete."))
    }

    /// A refused path must come back as a FAILED observation the model can
    /// react to — never a hang or a silent success. Deterministic: the
    /// workspace guard throws before any provider (or network) is touched.
    func testDescribeImageRefusalSurfacesAsFailedObservation() async throws {
        workspace.write("fake-png-bytes", to: "menu.png")
        engine.enqueue(texts: [
            toolCall("describe_image", #"{"path": "../outside.png"}"#),
            "The path was refused, so I cannot inspect that file. Task complete.",
        ])
        let loop = makeVisionLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "describe ../outside.png")
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: 10)
        _ = await collection

        XCTAssertNotNil(finish, "loop never finished")
        let results = toolResults(collector)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.failed, true)
        XCTAssertFalse(results.first?.output.isEmpty ?? true,
                       "the failure reason must reach the model")
    }
}
