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
        XCTAssertTrue(text.contains("Built-in browser, simulator & computer control"))
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
        XCTAssertFalse(text.contains("Built-in browser, simulator & computer control"))
    }

    func testComputerGuidanceAppearsWithComputerTools() {
        let text = prompt(tools: [StubTool(name: "computer_ui_tree")])
        XCTAssertTrue(text.contains("Computer control (computer_*)"))
        XCTAssertTrue(text.contains("observe → act → re-observe"))
    }

    /// The real default registry includes both tool families, so a real
    /// session's prompt always carries the full guidance.
    @MainActor
    func testDefaultToolsTriggerFullGuidance() {
        let names = Set(AgentSessionController.defaultTools.map(\.name))
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("sim_build_run"))
        XCTAssertTrue(names.contains("describe_image"))
        XCTAssertTrue(names.contains("computer_ui_tree"))
        XCTAssertTrue(names.contains("computer_click"))
        XCTAssertTrue(names.contains("glob"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertTrue(names.contains("create_macos_app"))
        XCTAssertTrue(names.contains("create_ios_app"))
        XCTAssertTrue(names.contains("macos_build_run"))
    }

    func testAppBuildGuidanceAppearsWithScaffoldTools() {
        let text = prompt(tools: [StubTool(name: "create_macos_app"), StubTool(name: "build_diagnostics")])
        XCTAssertTrue(text.contains("Delivering a native iOS or macOS app"))
        XCTAssertTrue(text.contains("create_macos_app"))
    }

    func testWebFetchAndTaskGuidanceAppearWhenRegistered() {
        let text = prompt(tools: [StubTool(name: "web_fetch"), StubTool(name: "task")])
        XCTAssertTrue(text.contains("Web fetch (web_fetch)"))
        XCTAssertTrue(text.contains("Subagents (task)"))
    }

    func testPlanModeInstructionsAreIncludedInTheModelPrompt() {
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file")],
            workspace: Workspace(root: tempRoot),
            planMode: true)
        XCTAssertTrue(text.contains("You are in PLAN mode"))
        XCTAssertTrue(text.contains("Do NOT call any tool yet"))
    }

    func testPromptBudgetLeavesRoomForAReply() {
        let oversizedInstructions = String(repeating: "workspace rule ", count: 4_000)
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file")],
            workspace: Workspace(root: tempRoot),
            projectInstructions: oversizedInstructions,
            contextWindowTokens: 8_192,
            responseReserveTokens: 2_048)
        XCTAssertLessThanOrEqual(text.count, 8_192 * 3)
        XCTAssertTrue(text.contains("read_file"))
    }

    func testLeanPromptOmitsWorkspaceContextAndAddsDirectAnswerGuidance() {
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file")],
            workspace: Workspace(root: tempRoot),
            projectInstructions: String(repeating: "rule ", count: 2_000),
            workspaceHistory: String(repeating: "history ", count: 2_000),
            leanPrompt: true)
        XCTAssertTrue(text.contains("Answer ordinary questions directly"))
        XCTAssertFalse(text.contains("# Project instructions"))
        XCTAssertFalse(text.contains("# Earlier work in this workspace"))
    }

    func testLeanPromptOmitsGoalModeProtocolExpansion() {
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file")],
            workspace: Workspace(root: tempRoot),
            goalMode: true,
            leanPrompt: true)
        XCTAssertTrue(text.contains("Answer ordinary questions directly"))
        XCTAssertFalse(text.contains("# Goal mode"))
    }
}
