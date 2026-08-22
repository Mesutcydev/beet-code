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
        let summary: String
        let risk = ToolRisk.read
        let schemaText: String

        init(name: String, summary: String = "stub", schemaText: String = "{}") {
            self.name = name
            self.summary = summary
            self.schemaText = schemaText
        }

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
        let text = PromptBuilder.capabilityGuidance(
            tools: [StubTool(name: "browser_navigate")]) ?? ""
        XCTAssertTrue(text.contains("Runtime capability map"))
        XCTAssertTrue(text.contains("In-app browser"))
        XCTAssertTrue(text.contains("`browser_navigate`"))
        XCTAssertFalse(text.contains("`browser_read`"))
        XCTAssertFalse(text.contains("`describe_image`"))
    }

    func testSimulatorGuidanceAppearsWithSimTools() {
        let text = PromptBuilder.capabilityGuidance(
            tools: [StubTool(name: "sim_build_run")]) ?? ""
        XCTAssertTrue(text.contains("Built-in iOS Simulator"))
        XCTAssertTrue(text.contains("build → install → launch → screenshot → describe"))
        XCTAssertFalse(text.contains("In-app browser"))
    }

    func testBothSectionsAppearWithFullToolset() {
        let text = PromptBuilder.capabilityGuidance(tools: [
            StubTool(name: "browser_navigate"),
            StubTool(name: "sim_list_devices"),
        ]) ?? ""
        XCTAssertTrue(text.contains("In-app browser"))
        XCTAssertTrue(text.contains("Built-in iOS Simulator"))
        XCTAssertFalse(text.contains("`sim_build_run`"))
    }

    func testCoreCodingToolsAlsoReceiveCapabilityGuidance() {
        let text = prompt(tools: [StubTool(name: "read_file")])
        XCTAssertTrue(text.contains("Runtime capability map"))
        XCTAssertTrue(text.contains("Inspect the workspace"))
        XCTAssertTrue(text.contains("`read_file`"))
    }

    func testNoCapabilityMapWithoutAnyTools() {
        XCTAssertNil(PromptBuilder.capabilityGuidance(tools: []))
    }

    func testComputerGuidanceAppearsWithComputerTools() {
        let text = PromptBuilder.capabilityGuidance(
            tools: [StubTool(name: "computer_ui_tree")]) ?? ""
        XCTAssertTrue(text.contains("Mac computer control"))
        XCTAssertTrue(text.contains("observe → act → re-observe"))
        XCTAssertFalse(text.contains("`computer_status`"))
    }

    /// The default coding registry includes browser, simulator, and Apple
    /// delivery tools. Computer-use stays opt-in.
    @MainActor
    func testDefaultToolsTriggerFullGuidance() {
        let names = Set(AgentSessionController.defaultTools.map(\.name))
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("sim_build_run"))
        XCTAssertTrue(names.contains("describe_image"))
        XCTAssertFalse(names.contains("computer_ui_tree"))
        XCTAssertFalse(names.contains("computer_click"))
        XCTAssertTrue(names.contains("glob"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertTrue(names.contains("create_macos_app"))
        XCTAssertTrue(names.contains("create_ios_app"))
        XCTAssertTrue(names.contains("macos_build_run"))
        XCTAssertTrue(names.contains("apple_ship"))
    }

    @MainActor
    func testComputerToolsJoinSessionWhenEnabled() {
        let names = Set(
            AgentSessionController.sessionTools(computerControlEnabled: true).map(\.name))
        XCTAssertTrue(names.contains("computer_ui_tree"))
        XCTAssertTrue(names.contains("computer_click"))
        XCTAssertTrue(names.contains("sim_build_run"))
    }

    func testAppBuildGuidanceAppearsWithScaffoldTools() {
        let text = prompt(tools: [
            StubTool(name: "create_macos_app"),
            StubTool(name: "build_diagnostics"),
            StubTool(name: "apple_ship"),
        ])
        XCTAssertTrue(text.contains("Create and deliver Apple apps"))
        XCTAssertTrue(text.contains("create_macos_app"))
        XCTAssertTrue(text.contains("apple_ship"))
        XCTAssertTrue(text.contains("only after verification"))
    }

    func testWebFetchAndTaskGuidanceAppearWhenRegistered() {
        let text = prompt(tools: [StubTool(name: "web_fetch"), StubTool(name: "task")])
        XCTAssertTrue(text.contains("Read the public web"))
        XCTAssertTrue(text.contains("Delegate focused work"))
    }

    func testUnknownExtensionToolIsDiscoverableWithItsSummary() {
        let text = PromptBuilder.capabilityGuidance(tools: [
            StubTool(name: "mcp__design__inspect", summary: "Inspect the current design document")
        ]) ?? ""
        XCTAssertTrue(text.contains("Connected extensions"))
        XCTAssertTrue(text.contains("`mcp__design__inspect`"))
        XCTAssertTrue(text.contains("Inspect the current design document"))
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

    func testCapabilityMapPrecedesAndSurvivesAShortenedSchemaCatalog() {
        let oversizedSchema = "{\"type\":\"object\",\"padding\":\""
            + String(repeating: "x", count: 20_000)
            + "END_OF_SCHEMA\"}"
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(
                name: "browser_navigate",
                summary: "Open a URL",
                schemaText: oversizedSchema)],
            workspace: Workspace(root: tempRoot),
            contextWindowTokens: 4_096,
            responseReserveTokens: 2_048)

        let map = text.range(of: "# Runtime capability map")
        let schemas = text.range(of: "# Tool argument schemas")
        XCTAssertNotNil(map)
        XCTAssertNotNil(schemas)
        if let map, let schemas {
            XCTAssertLessThan(map.lowerBound, schemas.lowerBound)
        }
        XCTAssertTrue(text.contains("`browser_navigate`"))
        XCTAssertFalse(text.contains("END_OF_SCHEMA"))
    }

    func testProjectInstructionsTakePriorityOverBulkySchemas() {
        let oversizedSchema = String(repeating: "schema ", count: 4_000)
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file", schemaText: oversizedSchema)],
            workspace: Workspace(root: tempRoot),
            projectInstructions: "MUST_USE_PROJECT_RULES",
            contextWindowTokens: 4_096,
            responseReserveTokens: 2_048)

        let instructions = text.range(of: "MUST_USE_PROJECT_RULES")
        let schemas = text.range(of: "# Tool argument schemas")
        XCTAssertNotNil(instructions)
        XCTAssertNotNil(schemas)
        if let instructions, let schemas {
            XCTAssertLessThan(instructions.lowerBound, schemas.lowerBound)
        }
    }

    func testLeanPromptOmitsWorkspaceContextAndAddsDirectAnswerGuidance() {
        let text = PromptBuilder.systemPrompt(
            tools: [StubTool(name: "read_file")],
            workspace: Workspace(root: tempRoot),
            projectInstructions: String(repeating: "rule ", count: 2_000),
            workspaceHistory: String(repeating: "history ", count: 2_000),
            leanPrompt: true)
        XCTAssertTrue(text.contains("Answer ordinary questions directly"))
        XCTAssertTrue(text.contains("Runtime capability map"))
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
