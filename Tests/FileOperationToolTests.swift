import XCTest
@testable import BeetCode

/// move_file / find_files — the two file-operation tools added for coding
/// agent coverage (refactors and name-based discovery).
final class FileOperationToolTests: XCTestCase {

    private var workspace: Workspace!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-fileops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspace = Workspace(root: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func call(_ name: String, _ arguments: [String: LFJSONValue]) -> ParsedToolCall {
        ParsedToolCall(name: name, arguments: .object(arguments), index: 0)
    }

    // MARK: move_file

    func testMoveRenamesFile() async throws {
        try "content".write(to: tempDir.appendingPathComponent("old.swift"), atomically: true, encoding: .utf8)
        let context = ToolContext(workspace: workspace)
        let output = try await MoveFileTool().execute(
            call("move_file", ["from": .string("old.swift"), "to": .string("Sources/new.swift")]),
            in: context)
        XCTAssertTrue(output.contains("old.swift → Sources/new.swift"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("old.swift").path))
        let moved = try String(contentsOf: tempDir.appendingPathComponent("Sources/new.swift"), encoding: .utf8)
        XCTAssertEqual(moved, "content")
    }

    func testMoveRefusesToOverwrite() async throws {
        try "a".write(to: tempDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let context = ToolContext(workspace: workspace)
        let output = try await MoveFileTool().execute(
            call("move_file", ["from": .string("a.swift"), "to": .string("b.swift")]),
            in: context)
        XCTAssertTrue(output.contains("refusing to overwrite"), output)
        // Both files untouched.
        XCTAssertEqual(try String(contentsOf: tempDir.appendingPathComponent("b.swift"), encoding: .utf8), "b")
    }

    func testMoveMissingSourceIsAnObservationNotACrash() async throws {
        let context = ToolContext(workspace: workspace)
        let output = try await MoveFileTool().execute(
            call("move_file", ["from": .string("nope.swift"), "to": .string("x.swift")]),
            in: context)
        XCTAssertTrue(output.contains("file not found"), output)
    }

    func testMoveOutsideWorkspaceIsRefused() async throws {
        try "secret".write(to: tempDir.appendingPathComponent("in.swift"), atomically: true, encoding: .utf8)
        let context = ToolContext(workspace: workspace)
        do {
            _ = try await MoveFileTool().execute(
                call("move_file", ["from": .string("in.swift"), "to": .string("../outside.swift")]),
                in: context)
            XCTFail("expected workspace refusal")
        } catch {
            // Workspace resolve throws — the file must stay put.
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("in.swift").path))
        }
    }

    // MARK: find_files

    func testFindFilesByGlob() async throws {
        try "x".write(to: tempDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try "x".write(to: tempDir.appendingPathComponent("Tests/AppTests.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let context = ToolContext(workspace: workspace)
        let output = try await FindFilesTool().execute(
            call("find_files", ["pattern": .string("*Tests.swift")]), in: context)
        XCTAssertTrue(output.contains("Tests/AppTests.swift"), output)
        XCTAssertFalse(output.contains("App.swift\n"), "anchored glob must not match non-Tests files: \(output)")
        XCTAssertFalse(output.contains("README.md"), output)
    }

    func testGlobAliasMatchesFindFiles() async throws {
        try "x".write(to: tempDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try "x".write(to: tempDir.appendingPathComponent("Tests/AppTests.swift"), atomically: true, encoding: .utf8)
        let context = ToolContext(workspace: workspace)
        let output = try await FindFilesTool(name: "glob").execute(
            call("glob", ["pattern": .string("*Tests.swift")]), in: context)
        XCTAssertTrue(output.contains("Tests/AppTests.swift"), output)
    }

    func testFindFilesSkipsNoiseAndSymlinks() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "x".write(to: tempDir.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
        let context = ToolContext(workspace: workspace)
        let output = try await FindFilesTool().execute(
            call("find_files", ["pattern": .string("*.js")]), in: context)
        XCTAssertTrue(output.contains("no files matching"), output)
    }

    // MARK: snapshot completeness (install detection)

    func testCompleteSnapshotRules() {
        // GGUF: the single weight file is enough, no config.json needed.
        XCTAssertTrue(ModelStore.isCompleteSnapshot(dirNames: ["model.gguf"]))
        // MLX: config + weights.
        XCTAssertTrue(ModelStore.isCompleteSnapshot(dirNames: ["config.json", "model.safetensors"]))
        // Interrupted downloads never count.
        XCTAssertFalse(ModelStore.isCompleteSnapshot(dirNames: ["model.gguf", "x.incomplete"]))
        XCTAssertFalse(ModelStore.isCompleteSnapshot(dirNames: ["config.json", "model.safetensors.incomplete"]))
        // Config without weights is not loadable.
        XCTAssertFalse(ModelStore.isCompleteSnapshot(dirNames: ["config.json", "tokenizer.json"]))
        XCTAssertFalse(ModelStore.isCompleteSnapshot(dirNames: []))
    }

    // MARK: background processes

    func testBackgroundProcessStartListStop() async throws {
        BackgroundProcessStore.resetAll()
        defer { BackgroundProcessStore.resetAll() }
        let context = ToolContext(workspace: workspace)
        let start = try await BackgroundProcessTool().execute(
            call("background_process", [
                "action": .string("start"),
                "command": .string("sleep 30"),
            ]),
            in: context)
        XCTAssertTrue(start.contains("started bg-"), start)
        let listed = try await BackgroundStatusTool().execute(
            call("background_status", ["action": .string("list")]), in: context)
        XCTAssertTrue(listed.contains("running"), listed)
        XCTAssertTrue(listed.contains("sleep 30"), listed)
        let id = listed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let stopped = try await BackgroundProcessTool().execute(
            call("background_process", ["action": .string("stop"), "id": .string(id)]),
            in: context)
        XCTAssertTrue(stopped.contains("stopped"), stopped)
    }
}
