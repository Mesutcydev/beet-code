import Foundation
import XCTest
@testable import BeetCode

final class AgentWorktreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"])
        try runGit(["config", "user.name", "Beet Code Tests"])
        try runGit(["config", "user.email", "tests@beetcode.local"])
        try "committed\n".write(
            to: root.appendingPathComponent("Tracked.txt"),
            atomically: true,
            encoding: .utf8)
        try runGit(["add", "Tracked.txt"])
        try runGit(["commit", "-m", "baseline"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSeedsDirtyTreeAndMergesChildResult() throws {
        let tracked = root.appendingPathComponent("Tracked.txt")
        let untracked = root.appendingPathComponent("Untracked.txt")
        try "parent dirty\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "parent untracked\n".write(to: untracked, atomically: true, encoding: .utf8)

        let worktree = try AgentWorktree.prepare(parentWorkspace: root)
        defer { try? worktree.remove() }
        XCTAssertEqual(
            try String(
                contentsOf: worktree.workspaceURL.appendingPathComponent("Tracked.txt"),
                encoding: .utf8),
            "parent dirty\n")
        XCTAssertEqual(
            try String(
                contentsOf: worktree.workspaceURL.appendingPathComponent("Untracked.txt"),
                encoding: .utf8),
            "parent untracked\n")

        try "child changed\n".write(
            to: worktree.workspaceURL.appendingPathComponent("Tracked.txt"),
            atomically: true,
            encoding: .utf8)
        try "created by child\n".write(
            to: worktree.workspaceURL.appendingPathComponent("Child.txt"),
            atomically: true,
            encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "parent dirty\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Child.txt").path))

        let summary = try worktree.merge()
        XCTAssertEqual(Set(summary.files), ["Tracked.txt", "Child.txt"])
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "child changed\n")
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("Child.txt"),
                encoding: .utf8),
            "created by child\n")
        XCTAssertEqual(
            try String(contentsOf: untracked, encoding: .utf8),
            "parent untracked\n")
    }

    func testRemoveUnregistersLinkedWorktree() throws {
        let worktree = try AgentWorktree.prepare(parentWorkspace: root)
        try worktree.remove()

        let listing = try runGit(["worktree", "list", "--porcelain"]).output
        XCTAssertFalse(listing.contains(worktree.workspaceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.workspaceURL.path))
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> CommandResult {
        let result = try ShellRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: root,
            timeout: 30)
        XCTAssertEqual(result.exitCode, 0, result.output)
        return result
    }
}
