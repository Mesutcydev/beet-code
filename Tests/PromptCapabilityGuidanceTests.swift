import Foundation
import XCTest
@testable import BeetCode

/// The system prompt must TEACH the model when to use the in-app browser and
/// the built-in simulator — a bare tool listing isn't enough for a model to
/// know it can verify web/iOS work visually. The guidance is derived from the
/// registered tools so it never advertises an absent capability.
final class PromptCapabilityGuidanceTests: XCTestCase {

    /// Minimal stand-in: capability detection keys off tool names only.
    private struct StubTool: AgentTool {
        let name: String
        let summary = "stub"
        let risk = ToolRisk.read
        let schemaText = "{}"
        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String { "" }
    }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-prompt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func prompt(tools: [any AgentTool]) -> String {
        PromptBuilder.systemPrompt(tools: tools, workspace: Workspace(root: tempRoot))
    }

    func testBrowserGuidanceAppearsWithBrowserTools() {
        let text = prompt(tools: [StubTool(name: "browser_navigate")])
        XCTAssertTrue(text.contains("Built-in browser & simulator"))
        XCTAssertTrue(text.contains("In-app browser"))
        XCTAssertFalse(text.contains("sim_build_run is the one-shot loop"))
    }

    func testSimulatorGuidanceAppearsWithSimTools() {
        let text = prompt(tools: [StubTool(name: "sim_build_run")])
        XCTAssertTrue(text.contains("Built-in iOS simulator"))
        XCTAssertFalse(text.contains("In-app browser"))
    }

    func testBothSectionsAppearWithFullToolset() {
        let text = prompt(tools: [
            StubTool(name: "browser_navigate"),
            StubTool(name: "sim_list_devices"),
        ])
        XCTAssertTrue(text.contains("In-app browser"))
        XCTAssertTrue(text.contains("Built-in iOS simulator"))
    }

    func testNoGuidanceWithoutMatchingTools() {
        let text = prompt(tools: [StubTool(name: "read_file")])
        XCTAssertFalse(text.contains("Built-in browser & simulator"))
    }

    /// The real default registry includes both tool families, so a real
    /// session's prompt always carries the full guidance.
    @MainActor
    func testDefaultToolsTriggerFullGuidance() {
        let names = Set(AgentSessionController.defaultTools.map(\.name))
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("sim_build_run"))
        XCTAssertTrue(names.contains("describe_image"))
    }
}
