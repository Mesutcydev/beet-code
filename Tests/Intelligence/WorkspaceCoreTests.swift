import Foundation
import XCTest
@testable import BeetCode

/// Phase 1 — Workspace identity + snapshots. Exercises the real scanner
/// against real temp directories and real git repositories (GitRepo fixture);
/// no mocks anywhere in this suite.
final class WorkspaceCoreTests: XCTestCase {

    // MARK: Identity

    func testSameWorkspaceResolvesConsistently() {
        let ws = TempWorkspace()
        ws.write("hello", to: "a.txt")
        let first = WorkspaceIdentity.resolve(root: ws.url)
        let second = WorkspaceIdentity.resolve(root: ws.url)
        XCTAssertEqual(first.workspaceID, second.workspaceID)
        XCTAssertEqual(first.canonicalPath, second.canonicalPath)
        XCTAssertTrue(first.workspaceID.hasPrefix("wks_"))
    }

    func testDifferentRepositoriesDoNotCollide() {
        let wsA = TempWorkspace()
        let wsB = TempWorkspace()
        let repoA = GitRepo(in: wsA)
        let repoB = GitRepo(in: wsB)
        // Different content → different trees → different root commits.
        // (Two repos with byte-identical trees, message, author and timestamp
        // second genuinely hash identically in Git itself.)
        wsA.write("project A", to: "file.txt")
        wsB.write("project B", to: "file.txt")
        repoA.commitAll(message: "root")
        repoB.commitAll(message: "root")

        let idA = WorkspaceIdentity.resolve(root: wsA.url)
        let idB = WorkspaceIdentity.resolve(root: wsB.url)
        XCTAssertNotEqual(idA.workspaceID, idB.workspaceID)
        XCTAssertNotEqual(idA.git?.rootCommit, idB.git?.rootCommit)
    }

    func testGitWorkspaceIdentitySurvivesMove() {
        let ws = TempWorkspace()
        let repo = GitRepo(in: ws)
        ws.write("content", to: "file.txt")
        repo.commitAll(message: "root")
        let before = WorkspaceIdentity.resolve(root: ws.url)

        // Move the whole working tree: identity must be unchanged.
        let movedURL = ws.url.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.moveItem(at: ws.url, to: movedURL)
        defer { try? FileManager.default.removeItem(at: movedURL) }

        let after = WorkspaceIdentity.resolve(root: movedURL)
        XCTAssertEqual(before.workspaceID, after.workspaceID)
        XCTAssertNotEqual(before.canonicalPath, after.canonicalPath)
    }

    func testBranchChangeDetected() {
        let ws = TempWorkspace()
        let repo = GitRepo(in: ws)
        ws.write("v1", to: "file.txt")
        repo.commitAll(message: "root")
        let initial = WorkspaceIdentity.resolve(root: ws.url)

        repo.run(["checkout", "-q", "-b", "feature/auth"])
        let switched = WorkspaceIdentity.resolve(root: ws.url)

        XCTAssertEqual(initial.workspaceID, switched.workspaceID)
        XCTAssertNotEqual(initial.git?.branch, switched.git?.branch)
        XCTAssertEqual(switched.git?.branch, "feature/auth")
    }

    // MARK: Snapshot delta

    private func snapshot(_ ws: TempWorkspace) -> WorkspaceSnapshot {
        WorkspaceScanner.capture(identity: WorkspaceIdentity.resolve(root: ws.url))
    }

    func testFileAdditionsDetected() {
        let ws = TempWorkspace()
        ws.write("one", to: "one.txt")
        let first = snapshot(ws)
        ws.write("two", to: "dir/two.txt")
        let second = snapshot(ws)

        let delta = second.delta(from: first)
        XCTAssertEqual(delta.added.map(\.relativePath), ["dir/two.txt"])
        XCTAssertTrue(delta.modified.isEmpty)
        XCTAssertTrue(delta.deleted.isEmpty)
    }

    func testModificationsDetected() {
        let ws = TempWorkspace()
        ws.write("before", to: "file.txt")
        let first = snapshot(ws)
        ws.write("after — different bytes", to: "file.txt")
        let second = snapshot(ws)

        let delta = second.delta(from: first)
        XCTAssertEqual(delta.modified.map(\.relativePath), ["file.txt"])
        XCTAssertNotEqual(
            first.files["file.txt"]?.contentHash,
            second.files["file.txt"]?.contentHash)
        XCTAssertTrue(delta.added.isEmpty)
    }

    func testDeletesDetected() {
        let ws = TempWorkspace()
        ws.write("gone soon", to: "doomed.txt")
        ws.write("stays", to: "keeper.txt")
        let first = snapshot(ws)
        try? FileManager.default.removeItem(at: ws.url(for: "doomed.txt"))
        let second = snapshot(ws)

        let delta = second.delta(from: first)
        XCTAssertEqual(delta.deleted.map(\.relativePath), ["doomed.txt"])
        XCTAssertTrue(delta.added.isEmpty)
    }

    func testRenamesDetectedAsMovesNotDeletePlusAdd() {
        let ws = TempWorkspace()
        ws.write("identical payload", to: "old/name.txt")
        let first = snapshot(ws)
        ws.write("identical payload", to: "new/name.txt")
        try? FileManager.default.removeItem(at: ws.url(for: "old/name.txt"))
        let second = snapshot(ws)

        let delta = second.delta(from: first)
        XCTAssertEqual(delta.renamed.count, 1)
        XCTAssertEqual(delta.renamed.first?.from.relativePath, "old/name.txt")
        XCTAssertEqual(delta.renamed.first?.to.relativePath, "new/name.txt")
        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.deleted.isEmpty)
    }

    func testIgnoredFilesExcluded() {
        let ws = TempWorkspace()
        ws.write("build/\ndist/\n*.log\n", to: ".gitignore")
        ws.write("keep me", to: "Sources/main.swift")
        ws.write("artifact", to: "build/output.o")
        ws.write("artifact", to: "dist/bundle.js")
        ws.write("noise", to: "debug.log")
        ws.write("dependency", to: "node_modules/lib/index.js")

        let snap = snapshot(ws)
        let paths = Set(snap.files.keys)
        XCTAssertTrue(paths.contains("Sources/main.swift"))
        XCTAssertTrue(paths.contains(".gitignore"))
        XCTAssertFalse(paths.contains("build/output.o"))
        XCTAssertFalse(paths.contains("dist/bundle.js"))
        XCTAssertFalse(paths.contains("debug.log"))
        XCTAssertFalse(paths.contains("node_modules/lib/index.js"))
    }

    func testNestedGitignoreScopesToItsDirectory() {
        let ws = TempWorkspace()
        ws.write("*.tmp", to: "sub/.gitignore")
        ws.write("x", to: "sub/scratch.tmp")
        ws.write("y", to: "root.tmp")          // only sub/ ignores *.tmp
        ws.write("z", to: "sub/deep/note.tmp") // nested rule reaches descendants

        let snap = snapshot(ws)
        let paths = Set(snap.files.keys)
        XCTAssertFalse(paths.contains("sub/scratch.tmp"))
        XCTAssertFalse(paths.contains("sub/deep/note.tmp"))
        XCTAssertTrue(paths.contains("root.tmp"))
    }

    func testNegationReincludes() {
        let ws = TempWorkspace()
        ws.write("*.log\n!important.log\n", to: ".gitignore")
        ws.write("a", to: "debug.log")
        ws.write("b", to: "important.log")

        let snap = snapshot(ws)
        XCTAssertNil(snap.files["debug.log"])
        XCTAssertNotNil(snap.files["important.log"])
    }

    func testOversizedFileRecordedWithoutHash() {
        let ws = TempWorkspace()
        // Sparse file over the 64 MB hash budget without allocating real bytes.
        let url = ws.url(for: "huge.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.truncate(atOffset: UInt64(SourceFileRecord.maxHashableBytes + 1))
        try! handle.close()

        let snap = snapshot(ws)
        let record = snap.files["huge.bin"]
        XCTAssertNotNil(record)
        XCTAssertNil(record?.contentHash)
        XCTAssertEqual(record?.sizeBytes, SourceFileRecord.maxHashableBytes + 1)
    }

    // MARK: Snapshot store

    func testSnapshotStoreRoundTrip() {
        let ws = TempWorkspace()
        let storeDir = TempWorkspace()
        let store = WorkspaceSnapshotStore()
        store.overrideDirectory = storeDir.url

        let snap = snapshot(ws)
        XCTAssertNil(store.loadLatest(workspaceID: snap.identity.workspaceID))
        store.save(snap)
        let loaded = store.loadLatest(workspaceID: snap.identity.workspaceID)
        // createdAt is persisted via ISO-8601 (millisecond precision) and is
        // capture metadata, not identity — compare the meaningful payload.
        XCTAssertEqual(loaded?.snapshotID, snap.snapshotID)
        XCTAssertEqual(loaded?.identity, snap.identity)
        XCTAssertEqual(loaded?.files, snap.files)
        XCTAssertEqual(loaded?.git, snap.git)
    }
}
