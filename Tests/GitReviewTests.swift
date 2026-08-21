import Foundation
import XCTest
@testable import BeetCode

final class GitReviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-review-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"])
        try runGit(["config", "user.name", "Beet Code Tests"])
        try runGit(["config", "user.email", "tests@beetcode.local"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadsFilesAndSeparatesDistantHunks() throws {
        let file = root.appendingPathComponent("Example.swift")
        try baselineLines().joined(separator: "\n").write(
            to: file,
            atomically: true,
            encoding: .utf8)
        try runGit(["add", "Example.swift"])
        try runGit(["commit", "-m", "baseline"])

        var changed = baselineLines()
        changed[1] = "changed two"
        changed[13] = "changed fourteen"
        try changed.joined(separator: "\n").write(
            to: file,
            atomically: true,
            encoding: .utf8)

        let files = try GitReviewService.load(workspace: root)
        XCTAssertEqual(files.map(\.path), ["Example.swift"])
        XCTAssertEqual(files[0].hunks.count, 2)
        XCTAssertEqual(files[0].diff.addedCount, 2)
        XCTAssertEqual(files[0].diff.removedCount, 2)
    }

    func testRejectsOneHunkAndCheckpointRestoresIt() throws {
        let fileURL = root.appendingPathComponent("Example.swift")
        try baselineLines().joined(separator: "\n").write(
            to: fileURL,
            atomically: true,
            encoding: .utf8)
        try runGit(["add", "Example.swift"])
        try runGit(["commit", "-m", "baseline"])

        var changed = baselineLines()
        changed[1] = "changed two"
        changed[13] = "changed fourteen"
        try changed.joined(separator: "\n").write(
            to: fileURL,
            atomically: true,
            encoding: .utf8)

        let checkpoint = try GitReviewService.makeCheckpoint(workspace: root)
        let reviewFile = try XCTUnwrap(GitReviewService.load(workspace: root).first)
        try GitReviewService.reject(
            hunk: try XCTUnwrap(reviewFile.hunks.first),
            in: reviewFile,
            workspace: root)

        let afterReject = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(afterReject.contains("line two"))
        XCTAssertTrue(afterReject.contains("changed fourteen"))

        try GitReviewService.restore(checkpoint, workspace: root)
        let restored = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("changed two"))
        XCTAssertTrue(restored.contains("changed fourteen"))
    }

    func testUntrackedPathWithSpacesIsReviewableAndRejectRemovesIt() throws {
        try "new file\n".write(
            to: root.appendingPathComponent("New File.swift"),
            atomically: true,
            encoding: .utf8)

        let file = try XCTUnwrap(GitReviewService.load(workspace: root).first)
        XCTAssertEqual(file.path, "New File.swift")
        XCTAssertTrue(file.isUntracked)
        try GitReviewService.reject(
            hunk: try XCTUnwrap(file.hunks.first),
            in: file,
            workspace: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("New File.swift").path))
    }

    private func baselineLines() -> [String] {
        (1...16).map { "line \(numberName($0))" }
    }

    private func numberName(_ value: Int) -> String {
        [
            1: "one", 2: "two", 3: "three", 4: "four",
            5: "five", 6: "six", 7: "seven", 8: "eight",
            9: "nine", 10: "ten", 11: "eleven", 12: "twelve",
            13: "thirteen", 14: "fourteen", 15: "fifteen", 16: "sixteen",
        ][value, default: String(value)]
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
