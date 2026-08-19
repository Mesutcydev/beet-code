import Foundation
import XCTest
@testable import BeetCode

/// Phase 16 — Git intelligence against a real temporary repository.
final class GitIntelligenceTests: XCTestCase {

    private var retained: [TempWorkspace] = []

    private func makeRepo() throws -> (TempWorkspace, GitRepo, GitIntelligence) {
        let ws = TempWorkspace()
        retained.append(ws)
        let repo = GitRepo(in: ws)

        ws.write("func alpha() { beta() }\nfunc beta() {}\n", to: "Sources/Core.swift")
        ws.write("line one\nline two\nline three\n", to: "README.md")
        repo.commitAll(message: "initial: core + readme")

        ws.write("func alpha() { beta() }\nfunc beta() {}\nfunc gamma() { alpha() }\n",
                 to: "Sources/Core.swift")
        repo.commitAll(message: "add gamma")

        ws.write("line one\nline two changed\nline three\n", to: "README.md")
        repo.commitAll(message: "edit readme")

        return (ws, repo, GitIntelligence(workspaceRoot: ws.url))
    }

    func testRecentCommits() throws {
        let (_, _, git) = try makeRepo()
        let commits = git.recentCommits(limit: 10)
        XCTAssertEqual(commits.count, 3)
        XCTAssertEqual(commits[0].subject, "edit readme") // newest first
        XCTAssertEqual(commits[2].subject, "initial: core + readme")
        XCTAssertEqual(commits[0].author, "BeetCode Tests")
        XCTAssertFalse(commits[0].hash.isEmpty)
    }

    func testFileHistoryFollowsOnlyThatFile() throws {
        let (_, _, git) = try makeRepo()
        let core = git.fileHistory(path: "Sources/Core.swift")
        XCTAssertEqual(core.map(\.subject), ["add gamma", "initial: core + readme"])
        let readme = git.fileHistory(path: "README.md")
        XCTAssertEqual(readme.map(\.subject), ["edit readme", "initial: core + readme"])
    }

    func testPickaxeFindsIntroducingCommit() throws {
        let (_, _, git) = try makeRepo()
        let commits = git.pickaxe("gamma")
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "add gamma")
    }

    func testChangeFrequency() throws {
        let (_, _, git) = try makeRepo()
        XCTAssertEqual(git.changeFrequency(path: "Sources/Core.swift", withinDays: 1), 2)
        XCTAssertEqual(git.changeFrequency(path: "README.md", withinDays: 1), 2)
        XCTAssertEqual(git.changeFrequency(path: "nonexistent.swift", withinDays: 1), 0)
    }

    func testBlameAttributesLines() throws {
        let (_, _, git) = try makeRepo()
        let blame = git.blame(path: "README.md")
        XCTAssertEqual(blame.count, 3)
        XCTAssertEqual(blame[0].author, "BeetCode Tests")
        XCTAssertEqual(blame[1].content, "line two changed")
        // Line 2 was changed in the second README commit; line 1 in the first.
        XCTAssertNotEqual(blame[0].commit, blame[1].commit)
        XCTAssertEqual(blame[0].commit, blame[2].commit)

        let ranged = git.blame(path: "README.md", lines: 2...2)
        XCTAssertEqual(ranged.count, 1)
        XCTAssertEqual(ranged[0].line, 2)
    }

    func testBranchContext() throws {
        let (ws, _, git) = try makeRepo()
        let clean = git.branchContext()
        XCTAssertNotNil(clean.branch)
        XCTAssertEqual(clean.dirtyFileCount, 0)
        XCTAssertNil(clean.ahead) // no upstream configured

        ws.write("dirty\n", to: "untracked.txt")
        XCTAssertEqual(git.branchContext().dirtyFileCount, 1)
    }

    func testNonRepoDegradesGracefully() {
        let ws = TempWorkspace()
        retained.append(ws)
        let git = GitIntelligence(workspaceRoot: ws.url)
        XCTAssertFalse(git.isAvailable)
        XCTAssertTrue(git.recentCommits().isEmpty)
        XCTAssertTrue(git.blame(path: "x").isEmpty)
        XCTAssertEqual(git.changeFrequency(path: "x"), 0)
    }

    func testPolicyGatesConsultation() {
        XCTAssertTrue(GitIntelligencePolicy.shouldConsult(
            taskDescription: "find the regression that broke login"))
        XCTAssertTrue(GitIntelligencePolicy.shouldConsult(
            taskDescription: "who changed this file last?"))
        XCTAssertTrue(GitIntelligencePolicy.shouldConsult(
            taskDescription: "show me the history of AuthService"))
        XCTAssertFalse(GitIntelligencePolicy.shouldConsult(
            taskDescription: "add a settings toggle"))
        XCTAssertFalse(GitIntelligencePolicy.shouldConsult(
            taskDescription: "refactor the parser to use actors"))
    }
}
