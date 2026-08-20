import Foundation
import XCTest
@testable import BeetCode

/// Slash-command parsing and the AGENTS.md/CLAUDE.md loader — both are pure
/// Core, so they test without any UI or engine.
final class SlashCommandTests: XCTestCase {

    func testParseKnownCommands() {
        XCTAssertEqual(SlashCommand.parse("/plan"), .plan)
        XCTAssertEqual(SlashCommand.parse("/auto"), .auto)
        XCTAssertEqual(SlashCommand.parse("/goal"), .goal)
        XCTAssertEqual(SlashCommand.parse("/undo"), .undo)
        XCTAssertEqual(SlashCommand.parse("/compact"), .compact)
        XCTAssertEqual(SlashCommand.parse("/help"), .help)
        XCTAssertEqual(SlashCommand.parse("/memory"), .memory)
        XCTAssertEqual(SlashCommand.parse("/model qwen3-1.7b-4bit"), .model("qwen3-1.7b-4bit"))
        XCTAssertEqual(SlashCommand.parse("/memory add always use swift-format"), .memoryAdd("always use swift-format"))
    }

    func testParseIsLenientWithWhitespace() {
        XCTAssertEqual(SlashCommand.parse("  /plan  "), .plan)
        XCTAssertEqual(SlashCommand.parse("/MODEL qwen3-4b-4bit"), .model("qwen3-4b-4bit"))
    }

    func testParseRejectsOrdinaryText() {
        XCTAssertNil(SlashCommand.parse("hello"))
        XCTAssertNil(SlashCommand.parse("plan the refactor"))
        XCTAssertNil(SlashCommand.parse(""))
    }

    func testMissingArgumentsFallBackToHelp() {
        XCTAssertEqual(SlashCommand.parse("/model"), .help)
        XCTAssertEqual(SlashCommand.parse("/memory add"), .help)
    }

    func testUnknownCommandsAreTagged() {
        XCTAssertEqual(SlashCommand.parse("/frobnicate"), .unknown("/frobnicate"))
    }
}

final class ProjectInstructionsTests: XCTestCase {

    var tempRoot: URL!

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-instructions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testNoInstructionsReturnsNil() {
        XCTAssertNil(ProjectInstructions.load(workspaceRoot: tempRoot))
    }

    func testAgentsMdWinsOverClaudeMd() throws {
        try "from AGENTS.md".write(to: tempRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "from CLAUDE.md".write(to: tempRoot.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(workspaceRoot: tempRoot)
        XCTAssertEqual(loaded?.source, "workspace AGENTS.md")
        XCTAssertEqual(loaded?.text, "from AGENTS.md")
    }

    func testClaudeMdIsUsedWhenAlone() throws {
        try "be concise".write(to: tempRoot.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(workspaceRoot: tempRoot)
        XCTAssertEqual(loaded?.source, "workspace CLAUDE.md")
        XCTAssertEqual(loaded?.text, "be concise")
    }

    func testOversizedInstructionsAreBounded() throws {
        let big = String(repeating: "x", count: ProjectInstructions.maxCharacters + 5_000)
        try big.write(to: tempRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(workspaceRoot: tempRoot)
        XCTAssertNotNil(loaded)
        XCTAssertLessThan(loaded!.text.count, big.count)
        XCTAssertTrue(loaded!.text.contains("[truncated"))
    }

    func testSectionRendersSourceAttribution() throws {
        try "run make test".write(to: tempRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let section = ProjectInstructions.section(workspaceRoot: tempRoot)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("run make test"))
        XCTAssertTrue(section!.contains("AGENTS.md"))
    }

    /// The system prompt must carry the instructions section through.
    func testSystemPromptIncludesInstructions() {
        let section = "Custom rules for this project."
        let prompt = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempRoot), projectInstructions: section)
        XCTAssertTrue(prompt.contains("Project instructions"))
        XCTAssertTrue(prompt.contains(section))
    }

    func testSystemPromptOmitsEmptyInstructions() {
        let prompt = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempRoot), projectInstructions: nil)
        XCTAssertFalse(prompt.contains("Project instructions"))
    }

    /// Cursor's `.cursor/rules/` directory loads as a rule pack: every
    /// markdown file, concatenated in name order.
    func testCursorRulesPackConcatenatesInNameOrder() throws {
        let rules = tempRoot.appendingPathComponent(".cursor/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try "style rules".write(to: rules.appendingPathComponent("01-style.md"), atomically: true, encoding: .utf8)
        try "testing rules".write(to: rules.appendingPathComponent("02-testing.mdc"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(workspaceRoot: tempRoot)
        XCTAssertEqual(loaded?.source, "workspace .cursor/rules")
        XCTAssertEqual(loaded?.text, "style rules\n\ntesting rules")
    }

    /// AGENTS.md still beats a Cursor rule pack when both exist.
    func testAgentsMdWinsOverCursorRules() throws {
        try "from AGENTS.md".write(to: tempRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let rules = tempRoot.appendingPathComponent(".cursor/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try "cursor rules".write(to: rules.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructions.load(workspaceRoot: tempRoot)?.source, "workspace AGENTS.md")
    }

    /// The legacy single-file `.cursorrules` convention still loads.
    func testLegacyCursorrulesFileLoads() throws {
        try "legacy cursor rules".write(to: tempRoot.appendingPathComponent(".cursorrules"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(workspaceRoot: tempRoot)
        XCTAssertEqual(loaded?.source, "workspace .cursorrules")
        XCTAssertEqual(loaded?.text, "legacy cursor rules")
    }
}

final class ProjectPolicyTests: XCTestCase {

    var tempRoot: URL!

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("beet-policy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLoadsJSONCPreferencesWithoutCredentials() throws {
        let text = """
        {
          // Shared project preferences; secrets stay in Keychain.
          "version": 1,
          "agent": "build",
          "plan": true,
          "verifyAfterEdits": true,
          "contextPaths": ["Sources", "Tests",],
          "deniedTools": ["computer_*"],
          "permissions": [
            {"action": "shell", "resource": "rm *", "effect": "deny"},
          ],
        }
        """
        try text.write(to: tempRoot.appendingPathComponent(".beetcode.jsonc"), atomically: true, encoding: .utf8)

        let policy = try XCTUnwrap(ProjectPolicy.load(workspaceRoot: tempRoot))
        XCTAssertEqual(policy.agent, "build")
        XCTAssertTrue(policy.plan == true)
        XCTAssertTrue(policy.verifyAfterEdits == true)
        XCTAssertTrue(policy.includesTool("read_file"))
        XCTAssertFalse(policy.includesTool("computer_click"))
        XCTAssertEqual(policy.openCodePermissions.effect(action: "shell", resource: "rm -rf /"), .deny)
        XCTAssertTrue(policy.promptSection.contains("Keychain"))
    }

    func testAllowedToolsAreAnAllowListAndDeniedToolsWin() {
        let policy = ProjectPolicy(
            allowedTools: ["read_*", "build_diagnostics"],
            deniedTools: ["read_file"])
        XCTAssertFalse(policy.includesTool("read_file"))
        XCTAssertTrue(policy.includesTool("read_directory"))
        XCTAssertTrue(policy.includesTool("build_diagnostics"))
        XCTAssertFalse(policy.includesTool("run_command"))
    }

    func testNormalJSONTakesPrecedenceOverJSONC() throws {
        try #"{"agent":"normal"}"#.write(
            to: tempRoot.appendingPathComponent(".beetcode.json"),
            atomically: true,
            encoding: .utf8)
        try #"{"agent":"jsonc"}"#.write(
            to: tempRoot.appendingPathComponent(".beetcode.jsonc"),
            atomically: true,
            encoding: .utf8)
        XCTAssertEqual(ProjectPolicy.load(workspaceRoot: tempRoot)?.agent, "normal")
    }

    func testPromptBuilderIncludesPolicySection() {
        let prompt = PromptBuilder.systemPrompt(
            tools: [],
            workspace: Workspace(root: tempRoot),
            projectPolicy: "Preferred agent: build")
        XCTAssertTrue(prompt.contains("# Project policy"))
        XCTAssertTrue(prompt.contains("Preferred agent: build"))
    }

    func testPromptBuilderEnforcesSelectedOutputStyle() {
        let concise = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempRoot), outputStyle: .concise)
        let detailed = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempRoot), outputStyle: .detailed)

        XCTAssertTrue(concise.contains("Keep the final answer concise"))
        XCTAssertTrue(detailed.contains("Give a detailed final answer"))
        XCTAssertNotEqual(concise, detailed)
    }
}
