import Foundation
import XCTest
@testable import BeetCode

final class NativeToolAndAppBuildTests: XCTestCase {

    func testOpenAIToolsEncodeSchemaAsObjectNotString() throws {
        let spec = NativeToolSpec(
            name: "write_file",
            description: "Write a file",
            schemaText: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#)
        let tools = NativeToolBridge.openAITools(from: [spec])
        let data = try JSONEncoder().encode(tools)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let function = try XCTUnwrap(json[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "write_file")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertNotNil(parameters["properties"] as? [String: Any])
    }

    func testGeminiToolsEncodeFunctionDeclarations() throws {
        let spec = NativeToolSpec(
            name: "read_file",
            description: "Read a file",
            schemaText: #"{"type":"object","properties":{"path":{"type":"string"}}}"#)
        let data = try JSONEncoder().encode(NativeToolBridge.geminiTools(from: [spec]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let declarations = try XCTUnwrap(json[0]["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations[0]["name"] as? String, "read_file")
        XCTAssertNotNil(declarations[0]["parameters"] as? [String: Any])
    }

    func testSerializeAccumulatedEmitsParserFence() {
        let fence = NativeToolBridge.serializeAccumulated([
            0: (name: "read_file", arguments: #"{"path":"A.swift"}"#),
        ])
        XCTAssertNotNil(fence)
        let calls = ToolParser.parse(fence ?? "")
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.string("path"), "A.swift")
    }

    func testOpenAIToolCallDeltaExtractsFragment() {
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"write_file","arguments":"{\"p\""}}]}}]}"#
        let extracted = RemoteLLMClient.extract(from: Data(json.utf8))
        XCTAssertEqual(extracted?.tool?.name, "write_file")
        XCTAssertEqual(extracted?.tool?.arguments, #"{"p""#)
    }

    func testGeminiFunctionCallExtractsAsToolFragment() {
        let json = #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read_file","args":{"path":"X.swift"}}}]}}]}"#
        let extracted = RemoteLLMClient.extract(from: Data(json.utf8))
        XCTAssertEqual(extracted?.tool?.name, "read_file")
        XCTAssertEqual(extracted?.tool?.arguments, #"{"path":"X.swift"}"#)
    }

    func testAnthropicToolUseStartAndJSONDelta() {
        let start = #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"build_diagnostics"}}"#
        XCTAssertEqual(RemoteLLMClient.extract(from: Data(start.utf8))?.tool?.name, "build_diagnostics")
        let delta = #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
        XCTAssertEqual(RemoteLLMClient.extract(from: Data(delta.utf8))?.tool?.arguments, "{}")
    }

    func testConsumeSSEFoldsToolCallFragments() async throws {
        let raw = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":""}}]}}]}"# + "\n"
            + #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"X.swift\"}"}}]}}]}"# + "\n"
            + "data: [DONE]\n"
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in Array(Data(raw.utf8)) { continuation.yield(byte) }
            continuation.finish()
        }
        final class Box: @unchecked Sendable { var texts: [String] = [] }
        let box = Box()
        try await RemoteLLMClient.consumeSSE(bytes: stream, onText: { box.texts.append($0) }, onUsage: { _ in })
        XCTAssertEqual(box.texts.count, 1, box.texts.joined())
        let calls = ToolParser.parse(box.texts[0])
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.string("path"), "X.swift")
    }

    func testBuildDiagnosticsPicksXcodebuildForXcodeproj() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = BuildDiagnosticsTool.defaultCommand(in: root)
        XCTAssertTrue(command.contains("xcodebuild"), command)
        XCTAssertTrue(command.contains("Demo.xcodeproj"), command)
        XCTAssertTrue(command.contains("platform=macOS"), command)
    }

    func testBuildDiagnosticsPicksSwiftBuildForSPM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-spm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(BuildDiagnosticsTool.defaultCommand(in: root), "swift build")
    }

    func testBuildDiagnosticsPicksSwiftTestWhenPackageHasTests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-spm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests/DemoTests"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(BuildDiagnosticsTool.defaultCommand(in: root), "swift test")
    }

    func testBuildDiagnosticsRunsXcodeTestsWhenTestSourcesExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-build-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("BeetCodeTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = BuildDiagnosticsTool.defaultCommand(in: root)
        XCTAssertTrue(command.hasSuffix(" test"), command)
        XCTAssertTrue(command.contains("-project 'Demo.xcodeproj'"), command)
    }

    func testCreateMacAppSanitizesProductName() {
        XCTAssertEqual(CreateMacAppTool.sanitizeProduct("my notes"), "MyNotes")
        XCTAssertEqual(CreateMacAppTool.sanitizeProduct("Hello-World!!"), "HelloWorld")
    }

    func testCreateMacAppWritesXcodeGenTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-scaffold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = CreateMacAppTool()
        let call = ParsedToolCall(
            name: "create_macos_app",
            arguments: .object(["name": .string("Demo Notes")]),
            index: 0)
        let output = try await tool.execute(call, in: ToolContext(workspace: Workspace(root: root)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/DemoNotesApp.swift").path), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path), output)
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("name: DemoNotes"), yml)
        XCTAssertEqual(BuildDiagnosticsTool.projectName(fromYML: root.appendingPathComponent("project.yml")), "DemoNotes")
    }

    func testReasoningHeuristicIncludesCodex() {
        XCTAssertTrue(RemoteLLMClient.usesMaxCompletionTokens("codex-mini"))
        XCTAssertTrue(RemoteLLMClient.usesMaxCompletionTokens("gpt-5.2"))
    }
}
