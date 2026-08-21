import XCTest
@testable import BeetCode

final class MLXModelInspectorTests: XCTestCase {

    func testReadRejectsNonRegularConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-model-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("config.json"),
            withIntermediateDirectories: false)

        XCTAssertNil(MLXModelInspector.read(from: directory))
    }

    func testReadRejectsOversizedConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-model-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: config.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: config)
        try handle.truncate(atOffset: MLXModelInspector.maximumConfigBytes + 1)
        try handle.close()

        XCTAssertNil(MLXModelInspector.read(from: directory))
    }

    func testQwen35MetadataUsesNestedTextConfigAndDetectsVLM() throws {
        let json: [String: Any] = [
            "architectures": ["Qwen3_5ForConditionalGeneration"],
            "model_type": "qwen3_5",
            "language_model_only": false,
            "text_config": ["max_position_embeddings": 262_144],
            "vision_config": ["hidden_size": 4096],
            "quantization_config": ["bits": 2],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let directory = URL(fileURLWithPath: "/tmp/Qwen3.8-27B-Uncensored-MLX/2-bit")

        let metadata = try XCTUnwrap(MLXModelInspector.metadata(from: data, directory: directory))
        XCTAssertEqual(metadata.family, "Qwen3.5")
        XCTAssertEqual(metadata.parameters, "27B")
        XCTAssertEqual(metadata.quantization, "2-bit")
        XCTAssertEqual(metadata.contextWindow, 262_144)
        XCTAssertTrue(metadata.isVisionLanguage)
    }

    func testGenericQuantizationFolderGetsStableModelID() {
        let directory = URL(fileURLWithPath: "/tmp/Qwen3.8-27B-Uncensored-MLX/2-bit")
        XCTAssertEqual(
            MLXModelInspector.suggestedID(for: directory),
            "Qwen3.8-27B-Uncensored-MLX-2-bit")
    }

    func testGenericQuantizationFolderUsesParentAsDisplayName() throws {
        let json: [String: Any] = [
            "model_type": "qwen3_5",
            "text_config": ["max_position_embeddings": 262_144],
            "vision_config": ["hidden_size": 4096],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let directory = URL(fileURLWithPath: "/tmp/Qwen3.8-27B-Uncensored-MLX/2-bit")
        let metadata = try XCTUnwrap(MLXModelInspector.metadata(from: data, directory: directory))

        XCTAssertEqual(
            MLXModelInspector.displayName(for: directory, metadata: metadata),
            "Qwen3.8 27B Uncensored MLX")
    }

    func testOrdinaryMLXModelKeepsItsFolderID() {
        let directory = URL(fileURLWithPath: "/tmp/Qwen3-8B-4bit")
        XCTAssertEqual(MLXModelInspector.suggestedID(for: directory), "Qwen3-8B-4bit")
    }

    func testTextOnlyQwen35UsesRootConfigAndStaysOnLLMFactory() throws {
        let json: [String: Any] = [
            "architectures": ["Qwen3_5ForCausalLM"],
            "model_type": "qwen3_5_text",
            "max_position_embeddings": 262_144,
            "quantization_config": ["bits": 4],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let directory = URL(fileURLWithPath: "/tmp/Qwen3.5-9B-abliterated-MLX-4bit")

        let metadata = try XCTUnwrap(MLXModelInspector.metadata(from: data, directory: directory))
        XCTAssertEqual(metadata.family, "Qwen3.5 Text")
        XCTAssertEqual(metadata.parameters, "9B")
        XCTAssertEqual(metadata.quantization, "4-bit")
        XCTAssertEqual(metadata.contextWindow, 262_144)
        XCTAssertFalse(metadata.isVisionLanguage)
    }

    func testClassicQwenCausalConfigsStayNonVision() throws {
        let fixtures: [(String, String, String)] = [
            ("qwen2", "Qwen2ForCausalLM", "/tmp/Qwen2.5-7B-4bit"),
            ("qwen3", "Qwen3ForCausalLM", "/tmp/Qwen3-8B-4bit"),
        ]

        for (modelType, architecture, path) in fixtures {
            let json: [String: Any] = [
                "architectures": [architecture],
                "model_type": modelType,
                "max_position_embeddings": 32_768,
                "quantization": ["bits": 4],
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            let metadata = try XCTUnwrap(
                MLXModelInspector.metadata(
                    from: data,
                    directory: URL(fileURLWithPath: path)))
            XCTAssertFalse(metadata.isVisionLanguage, "(modelType) must use the LLM factory")
            XCTAssertEqual(metadata.quantization, "4-bit")
        }
    }

    /// Opt-in because it pages the user's multi-gigabyte checkpoint into
    /// Metal. Create /tmp/beetcode-qwen35-smoke to run it explicitly.
    func testLiveQwen35TextSmoke() async throws {
        let marker = "/tmp/beetcode-qwen35-smoke"
        guard FileManager.default.fileExists(atPath: marker) else { return }

        let directory = URL(fileURLWithPath: "/Users/m/Desktop/Qwen3.8-27B-Uncensored-MLX/2-bit")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            XCTFail("Qwen3.5 test model is not present at \(directory.path)")
            return
        }

        let model = MLXEngine()
        try await model.load(
            directory: directory,
            modelID: MLXModelInspector.suggestedID(for: directory),
            diskBytes: (try? ModelStore.sizeOfDirectory(directory)) ?? 0)

        var output = ""
        let stream = model.stream(
            adding: [ChatTurn(role: .user, content: "Reply with exactly OK.")],
            maxTokens: 8,
            temperature: 0)
        for try await chunk in stream {
            output += chunk
        }
        await model.unload()

        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
