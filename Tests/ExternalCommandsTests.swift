import Foundation
import XCTest
@testable import BeetCode

/// Universal compatibility discovery: Claude skills/commands, Codex prompts
/// and BeetCode's own commands are found in their convention directories,
/// deduplicated by name with workspace-over-home precedence. Pure file
/// scanning over temp directories — no real home folder is touched.
final class ExternalCommandsTests: XCTestCase {

    var tempHome: URL!
    var tempWorkspace: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-external-commands-\(UUID().uuidString)")
        tempHome = base.appendingPathComponent("home")
        tempWorkspace = base.appendingPathComponent("workspace")
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome.deletingLastPathComponent())
    }

    // MARK: Helpers

    private func write(_ text: String, _ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Tests

    func testDiscoversClaudeSkillAndCodexPrompt() throws {
        try write("Review the diff.", ".claude/skills/review/SKILL.md", in: tempHome)
        try write("Fix the build.", ".codex/prompts/fix.md", in: tempHome)

        let commands = ExternalCommands.discover(home: tempHome, workspace: tempWorkspace)

        XCTAssertEqual(commands.count, 2)
        let skill = try XCTUnwrap(commands.first { $0.name == "review" })
        XCTAssertEqual(skill.origin, .claude)
        XCTAssertEqual(skill.kind, .skill)
        XCTAssertEqual(skill.text, "Review the diff.")
        let prompt = try XCTUnwrap(commands.first { $0.name == "fix" })
        XCTAssertEqual(prompt.origin, .codex)
        XCTAssertEqual(prompt.kind, .prompt)
    }

    func testDiscoversBeetCodeOwnCommands() throws {
        try write("Ship it.", ".beetcode/commands/ship.md", in: tempWorkspace)

        let commands = ExternalCommands.discover(home: tempHome, workspace: tempWorkspace)

        let command = try XCTUnwrap(commands.first { $0.name == "ship" })
        XCTAssertEqual(command.origin, .beetcode)
        XCTAssertEqual(command.kind, .command)
    }

    func testWorkspaceWinsNameCollision() throws {
        try write("home version", ".claude/commands/deploy.md", in: tempHome)
        try write("workspace version", ".claude/commands/deploy.md", in: tempWorkspace)

        let commands = ExternalCommands.discover(home: tempHome, workspace: tempWorkspace)

        XCTAssertEqual(commands.filter { $0.name == "deploy" }.count, 1)
        let deploy = try XCTUnwrap(commands.first { $0.name == "deploy" })
        XCTAssertEqual(deploy.text, "workspace version")
        // /var is a symlink to /private/var on macOS — compare resolved paths.
        let resolvedLocation = (deploy.location.path as NSString).resolvingSymlinksInPath
        let resolvedWorkspace = (tempWorkspace.path as NSString).resolvingSymlinksInPath
        XCTAssertTrue(resolvedLocation.hasPrefix(resolvedWorkspace))
    }

    func testEmptyFilesAndMissingDirectoriesAreSkipped() throws {
        try write("   \n", ".claude/commands/blank.md", in: tempHome)

        let commands = ExternalCommands.discover(home: tempHome, workspace: tempWorkspace)

        XCTAssertTrue(commands.isEmpty)
    }

    func testLookupIsCaseInsensitiveAndMatchesSlashNames() throws {
        try write("Review the diff.", ".claude/skills/Review/SKILL.md", in: tempHome)

        let command = ExternalCommands.command(named: "REVIEW", home: tempHome, workspace: nil)

        XCTAssertEqual(command?.name, "review")
        XCTAssertEqual(command?.text, "Review the diff.")
    }

    func testOversizedCommandTextIsBounded() throws {
        let big = String(repeating: "y", count: ExternalCommands.maxCharacters + 5_000)
        try write(big, ".codex/prompts/huge.md", in: tempHome)

        let command = ExternalCommands.command(named: "huge", home: tempHome, workspace: nil)

        XCTAssertNotNil(command)
        XCTAssertLessThan(command!.text.count, big.count)
        XCTAssertTrue(command!.text.contains("[truncated"))
    }
}
