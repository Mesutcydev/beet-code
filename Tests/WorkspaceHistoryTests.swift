import Foundation
import XCTest
@testable import BeetCode

/// Workspace-aware history: per-folder session filtering, the bounded
/// system-prompt digest, and the store's TTL cache contract. Pure Core —
/// temp-directory store, deterministic records, no real home directory.
final class WorkspaceHistoryTests: XCTestCase {

    var tempDir: URL!
    var store: SessionStore!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SessionStore()
        store.overrideSessionsDir = tempDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func record(_ title: String, path: String, source: SessionSource,
                        day: TimeInterval, userAsked: String? = nil) -> SessionRecord {
        let date = Date(timeIntervalSince1970: day)
        return SessionRecord(
            id: UUID(), title: title,
            createdAt: date, updatedAt: date,
            workspacePath: path, modelID: "m",
            messages: userAsked.map {
                [SessionMessage(role: .user, content: $0, toolName: nil, timestamp: date)]
            } ?? [],
            checkpoints: [], source: source)
    }

    // MARK: Filtering

    func testSessionsFiltersByWorkspaceNewestFirst() {
        store.save(record("a", path: "/proj", source: .app, day: 100))
        store.save(record("b", path: "/proj", source: .claude, day: 300))
        store.save(record("c", path: "/other", source: .codex, day: 200))

        let matches = WorkspaceHistory.sessions(workspacePath: "/proj", store: store)

        XCTAssertEqual(matches.map(\.title), ["b", "a"])
    }

    func testSectionIsNilWithoutHistory() {
        XCTAssertNil(WorkspaceHistory.section(workspacePath: "/nothing-here", store: store))
    }

    // MARK: Digest

    func testSectionSummarizesSourcesAndTopics() {
        store.save(record("own work", path: "/proj", source: .app, day: 100,
                          userAsked: "fix the diagnostics parser"))
        store.save(record("claude chat", path: "/proj", source: .claude, day: 200,
                          userAsked: "bump the version to 1.7"))
        store.save(record("codex chat", path: "/proj", source: .codex, day: 300))

        let section = WorkspaceHistory.section(workspacePath: "/proj", store: store)

        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("1 Beet Code"))
        XCTAssertTrue(section!.contains("1 Claude"))
        XCTAssertTrue(section!.contains("1 Codex"))
        XCTAssertTrue(section!.contains("bump the version to 1.7"))
        // Falls back to the title when a session has no user message.
        XCTAssertTrue(section!.contains("codex chat"))
    }

    func testSectionIsBounded() {
        for index in 0..<20 {
            store.save(record("long \(index)", path: "/proj", source: .claude,
                              day: TimeInterval(index),
                              userAsked: String(repeating: "x", count: 200)))
        }
        let section = WorkspaceHistory.section(workspacePath: "/proj", store: store)
        XCTAssertNotNil(section)
        // Header + bounded lines: never a context-window eater.
        XCTAssertLessThan(section!.count, WorkspaceHistory.maxCharacters + 300)
    }

    // MARK: Cache contract

    func testCachedAllInvalidatesOnSaveAndDelete() {
        XCTAssertEqual(store.cachedAll().count, 0)
        let first = record("one", path: "/p", source: .app, day: 1)
        let second = record("two", path: "/p", source: .app, day: 2)
        store.save(first)
        store.save(second)
        XCTAssertEqual(store.cachedAll().count, 2)
        store.delete(first)
        XCTAssertEqual(store.cachedAll().map(\.title), ["two"])
    }

    func testCachedAllReusesSnapshotWithinTTL() throws {
        _ = store.cachedAll()  // prime the cache (empty snapshot)
        // A write that BYPASSES save() (no invalidation): invisible inside
        // the TTL, visible once the budget expires.
        let manual = record("manual", path: "/p", source: .app, day: 1)
        let data = try JSONEncoder().encode(manual)
        try data.write(to: tempDir.appendingPathComponent("\(manual.id.uuidString).session"))
        XCTAssertEqual(store.cachedAll(maxAge: 60).count, 0)
        XCTAssertEqual(store.cachedAll(maxAge: 0).count, 1)
    }

    // MARK: Prompt plumbing

    func testPromptIncludesHistorySection() {
        let prompt = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempDir),
            workspaceHistory: "digest text")
        XCTAssertTrue(prompt.contains("# Earlier work in this workspace"))
        XCTAssertTrue(prompt.contains("digest text"))
    }

    func testPromptOmitsHistorySectionWhenNil() {
        let prompt = PromptBuilder.systemPrompt(
            tools: [], workspace: Workspace(root: tempDir))
        XCTAssertFalse(prompt.contains("Earlier work in this workspace"))
    }
}
