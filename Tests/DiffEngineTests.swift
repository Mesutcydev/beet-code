import XCTest
@testable import BeetCode

final class DiffEngineTests: XCTestCase {

    func testNoChange() {
        let result = DiffEngine.diff(old: "a\nb\nc", new: "a\nb\nc")
        XCTAssertTrue(result.isEmpty)
    }

    func testAppend() {
        let result = DiffEngine.diff(old: "a\nb", new: "a\nb\nc")
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(result.unified.contains("+ c"))
    }

    func testModification() {
        let result = DiffEngine.diff(old: "let x = 1", new: "let x = 2")
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertTrue(result.unified.contains("- let x = 1"))
        XCTAssertTrue(result.unified.contains("+ let x = 2"))
    }

    func testContextIsTrimmed() {
        let old = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 50", with: "line 50 changed")
        let result = DiffEngine.diff(old: old, new: new)
        XCTAssertLessThan(result.lines.count, 20, "100-line file with one change should collapse context")
        XCTAssertTrue(result.unified.contains("⋯"))
    }

    func testHugeInputFallsBackToReplace() {
        let old = (0..<3000).map { "a\($0)" }.joined(separator: "\n")
        let new = (0..<3000).map { "b\($0)" }.joined(separator: "\n")
        let result = DiffEngine.diff(old: old, new: new)
        XCTAssertFalse(result.isEmpty)
        XCTAssertGreaterThan(result.addedCount, 0)
    }

    func testSideBySidePairsReplacement() {
        let result = DiffEngine.diff(old: "let x = 1", new: "let x = 2")
        let rows = result.sideBySide
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left, "let x = 1")
        XCTAssertEqual(rows[0].leftKind, .removed)
        XCTAssertEqual(rows[0].right, "let x = 2")
        XCTAssertEqual(rows[0].rightKind, .added)
    }

    func testSideBySideKeepsContextOnBothSides() {
        let result = DiffEngine.diff(old: "a\nb\nc", new: "a\nB\nc")
        let rows = result.sideBySide
        XCTAssertTrue(rows.contains(where: { $0.left == "a" && $0.right == "a" }))
        XCTAssertTrue(rows.contains(where: { $0.left == "b" && $0.right == "B" }))
    }
}

final class WorkspaceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRelativePathResolvesInsideRoot() throws {
        let workspace = Workspace(root: tempDir)
        let url = try workspace.resolve("Sources/App.swift")
        // The resolved URL must be the workspace's canonical root joined with
        // the relative path. Use the same canonicalizer as the resolver:
        // Foundation's resolvingSymlinksInPath keeps /var while realpath
        // yields /private/var, and mixing the two forms would false-fail.
        let canonicalRoot = Workspace.resolvingSymlinks(tempDir)
        XCTAssertEqual(url.path, canonicalRoot.appendingPathComponent("Sources/App.swift").path)
        // And it must be contained.
        XCTAssertTrue(url.path.hasPrefix(canonicalRoot.path + "/"))
    }

    func testEscapeIsRefused() throws {
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("../../etc/passwd")) { error in
            guard case ToolError.pathOutsideWorkspace = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertThrowsError(try workspace.resolve("/etc/passwd")) { error in
            guard case ToolError.pathOutsideWorkspace = error else {
                return XCTFail("absolute path outside root must be refused")
            }
        }
    }

    func testSiblingPrefixIsRefused() throws {
        let sibling = tempDir.deletingLastPathComponent()
            .appendingPathComponent(tempDir.lastPathComponent + "-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve(sibling.path)) { error in
            guard case ToolError.pathOutsideWorkspace = error else {
                return XCTFail("sibling prefix must not be considered contained")
            }
        }
    }

    func testSymlinkOutsideIsRefusedForReadAndWrite() throws {
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("link/secret.txt", access: .read))
        XCTAssertThrowsError(try workspace.resolve("link/new.txt", access: .write))
    }

    func testSymlinkedWorkspaceRootIsInvalid() throws {
        let real = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let link = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-root-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try Workspace(root: link).resolve("file.txt")) { error in
            guard case ToolError.invalidWorkspaceRoot = error else {
                return XCTFail("expected invalidWorkspaceRoot, got \(error)")
            }
        }
    }

    // MARK: Phase 1.4 security regression matrix

    func testTildeAndHomePathsAreRefused() throws {
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("~/secret.txt"))
        XCTAssertThrowsError(try workspace.resolve("~"))
        let home = NSHomeDirectory()
        XCTAssertThrowsError(try workspace.resolve(home))
    }

    func testNormalizedDotPathsResolveInside() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("a/b"),
            withIntermediateDirectories: true)
        try "content".write(
            toFile: tempDir.appendingPathComponent("a/b/file.txt").path,
            atomically: true, encoding: .utf8)
        let workspace = Workspace(root: tempDir)
        // a/../b/file.txt standardizes to a/b/file.txt — inside.
        let url = try workspace.resolve("a/../b/file.txt")
        XCTAssertEqual(url.lastPathComponent, "file.txt")
        // Doubled slashes and trailing slashes standardize.
        _ = try workspace.resolve("a//b/file.txt")
        _ = try workspace.resolve("a/b/file.txt/")
    }

    func testAbsolutePathInsideWorkspaceIsAllowed() throws {
        try "content".write(
            toFile: tempDir.appendingPathComponent("inside.txt").path,
            atomically: true, encoding: .utf8)
        let workspace = Workspace(root: tempDir)
        // The canonical root may differ from the given root (/var → /private/var),
        // so containment must use canonical paths on both sides.
        let url = try workspace.resolve(tempDir.appendingPathComponent("inside.txt").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSymlinkedParentOutsideIsRefusedForNewFile() throws {
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = tempDir.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("linkdir/new.txt", access: .write))
    }

    func testSymlinkedParentInsideIsRefusedForNewFile() throws {
        // Even when the link resolves inside the workspace, creating a NEW
        // file through a symlinked parent is refused: a retargeted link would
        // redirect the write outside.
        let real = tempDir.appendingPathComponent("real");
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("linkdir/new.txt", access: .write))
        // Reading an existing file through the link is fine.
        try "content".write(
            toFile: real.appendingPathComponent("exists.txt").path,
            atomically: true, encoding: .utf8)
        let url = try workspace.resolve("linkdir/exists.txt", access: .read).url
        XCTAssertTrue(url.path.contains("real"))
    }

    func testSymlinkRetargetingIsResolvedPerCall() throws {
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside".write(
            toFile: outside.appendingPathComponent("file.txt").path,
            atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("retarget")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let workspace = Workspace(root: tempDir)
        // Initially the link points outside → refused.
        XCTAssertThrowsError(try workspace.resolve("retarget/file.txt", access: .read))
        // Retarget the link to a directory inside the workspace.
        let inside = tempDir.appendingPathComponent("inside");
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try "inside".write(
            toFile: inside.appendingPathComponent("file.txt").path,
            atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        let url = try workspace.resolve("retarget/file.txt", access: .read).url
        XCTAssertTrue(url.path.contains("inside"))
    }

    func testNewFileBeneathOutsideSymlinkIsRefused() throws {
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = tempDir.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("escape/pwned.txt", access: .write))
    }

    func testRootReplacedBySymlinkFailsClosed() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-rootswap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "inside".write(toFile: root.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)

        let workspace = Workspace(root: root)
        // Works before the swap.
        _ = try workspace.resolve("f.txt")

        // Replace the root directory with a symlink to another directory.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)

        // Every operation now fails closed — no silent redirection.
        XCTAssertThrowsError(try workspace.resolve("f.txt"))
        XCTAssertThrowsError(try workspace.resolve("new.txt", access: .write))
    }

    func testWriteThroughSymlinkedFileTargetOutsideIsRefused() throws {
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("lf-outside-w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "victim".write(toFile: outside.appendingPathComponent("victim.txt").path, atomically: true, encoding: .utf8)
        // A symlinked FILE inside the workspace pointing outside.
        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("victim.txt"))
        let workspace = Workspace(root: tempDir)
        XCTAssertThrowsError(try workspace.resolve("link.txt", access: .write), "writing through an escaping file symlink must be refused")
    }
}