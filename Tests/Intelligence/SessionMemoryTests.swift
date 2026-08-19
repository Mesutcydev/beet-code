import Foundation
import XCTest
@testable import BeetCode

/// Phase 10+11 — branch-aware working state and provider handoff.
final class SessionMemoryTests: XCTestCase {

    private func makeStore() throws -> WorkingStateStore {
        try WorkingStateStore(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
    }

    func testRoundTrip() throws {
        let store = try makeStore()
        var state = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "main")
        state.objective = "Fix reconnect behavior"
        state.plan = ["[x] Trace lifecycle", "Adjust timeout"]
        state.touchedFiles = ["SessionController.swift"]
        state.hypotheses = ["Inactive scene state triggers disconnect too aggressively"]
        state.failingTests = ["testBackgroundRecovery"]
        state.passingTests = 7
        state.totalTests = 8
        state.diffDigest = "2 files +38 -12"
        try store.save(state)

        let loaded = try store.load(workspaceID: "wks_1", branch: "main",
                                    sessionID: state.sessionID)
        XCTAssertEqual(loaded?.objective, state.objective)
        XCTAssertEqual(loaded?.plan, state.plan)
        XCTAssertEqual(loaded?.touchedFiles, state.touchedFiles)
        XCTAssertEqual(loaded?.passingTests, 7)
        XCTAssertEqual(loaded?.diffDigest, "2 files +38 -12")
    }

    func testBranchIsolation() throws {
        let store = try makeStore()
        var mainState = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "main")
        mainState.objective = "main work"
        var featureState = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "feature/auth")
        featureState.objective = "replacing credential storage"
        try store.save(mainState)
        try store.save(featureState)

        // Switching branches must not leak temporary state (spec §19).
        XCTAssertEqual(try store.latest(workspaceID: "wks_1", branch: "main")?.objective,
                       "main work")
        XCTAssertEqual(try store.latest(workspaceID: "wks_1", branch: "feature/auth")?.objective,
                       "replacing credential storage")
        XCTAssertNil(try store.latest(workspaceID: "wks_1", branch: "fix/reconnect"))
    }

    func testSessionDeletionKeepsOtherSessions() throws {
        let store = try makeStore()
        var a = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "main")
        a.objective = "session A"
        var b = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "main")
        b.objective = "session B"
        try store.save(a)
        try store.save(b)
        try store.delete(workspaceID: "wks_1", branch: "main", sessionID: a.sessionID)

        XCTAssertNil(try store.load(workspaceID: "wks_1", branch: "main", sessionID: a.sessionID))
        XCTAssertEqual(try store.load(workspaceID: "wks_1", branch: "main", sessionID: b.sessionID)?.objective,
                       "session B")
    }

    func testHandoffPacketContent() throws {
        var state = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "fix/reconnect")
        state.objective = "Fix reconnect behavior"
        state.plan = ["[x] Traced lifecycle", "[x] Identified premature teardown", "Adjust host timeout"]
        state.hypotheses = ["Inactive scene state triggers disconnect too aggressively"]
        state.touchedFiles = ["SessionController.swift", "RemoteSession.swift"]
        state.passingTests = 7
        state.totalTests = 8
        state.failingTests = ["testBackgroundRecovery"]
        state.openQuestions = ["Determine whether host timeout needs adjustment"]
        state.diffDigest = "2 files +38 -12"

        let pitfall = KnowledgeRecord(
            id: "kn_pitfall4", kind: .pitfall, scope: "Session lifecycle",
            statement: "Reconnect created a second RemoteSession.",
            confidence: .verified, freshness: .fresh, evidence: [],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        let packet = HandoffCompiler.compileWithProgress(
            state: state, relevantKnowledge: [pitfall])

        XCTAssertEqual(packet.goal, "Fix reconnect behavior")
        XCTAssertEqual(packet.completed, ["Traced lifecycle", "Identified premature teardown"])
        XCTAssertEqual(packet.knownPitfallIDs, ["kn_pitfall4"])
        let text = packet.rendered()
        XCTAssertTrue(text.contains("7/8 passing"))
        XCTAssertTrue(text.contains("testBackgroundRecovery"))
        XCTAssertTrue(text.contains("PITFALL") == false) // IDs, not prose injection
        XCTAssertTrue(text.contains("kn_pitfall4"))
    }

    func testHandoffSmallerThanTranscript() throws {
        var state = WorkingState(sessionID: UUID(), workspaceID: "wks_1", branch: "main")
        state.objective = "Refactor cache"
        state.touchedFiles = ["A.swift", "B.swift"]
        let packet = HandoffCompiler.compile(state: state)

        // A realistic session transcript dwarfs the packet — that's the
        // entire point of structured handoff (spec §16).
        let fakeTranscript = String(repeating: "assistant: analyzed the repository structure…\n", count: 500)
        XCTAssertLessThan(packet.rendered().count, fakeTranscript.count / 10)
    }
}
