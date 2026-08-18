import Foundation
import XCTest
@testable import BeetCode

// MARK: - Stream display filter ("thinking thinking…" fix)

final class StreamDisplayFilterTests: XCTestCase {

    func testCompleteThinkBlockHidden() {
        let raw = "<think>I must consider the file layout.</think>The fix is here."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "The fix is here.")
        XCTAssertFalse(reasoning)
    }

    func testOpenThinkBlockShowsReasoningState() {
        let raw = "<think>still pondering…"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "")
        XCTAssertTrue(reasoning)
    }

    func testRepetitionFillerIsReasoning() {
        let raw = "thinking thinking thinking thinking thinking"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertTrue(reasoning)
        XCTAssertFalse(visible.contains("thinking"))
    }

    func testRepetitionFollowedByRealTextKeepsText() {
        let raw = "thinking thinking thinking thinking\nHere is the answer."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertFalse(reasoning)
        XCTAssertEqual(visible, "thinking thinking thinking thinking Here is the answer.")
    }

    func testNormalTextUntouched() {
        let raw = "Refactor the parser into two functions."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, raw)
        XCTAssertFalse(reasoning)
    }

    func testFillerDetectionBoundaries() {
        // 3 repeats is NOT filler (needs 4+).
        XCTAssertFalse(StreamDisplayFilter.hasRepetitionFillerTail("thinking thinking thinking"))
        // Different words at the tail break the run.
        XCTAssertFalse(StreamDisplayFilter.hasRepetitionFillerTail("thinking thinking thinking now"))
        // Case + punctuation normalization.
        XCTAssertTrue(StreamDisplayFilter.hasRepetitionFillerTail("Hmm, hmm HMM. hmm hmm"))
        // Short words (< 2 chars) never count as filler.
        XCTAssertFalse(StreamDisplayFilter.hasRepetitionFillerTail("a a a a a a"))
    }
}

// MARK: - Approval overrides ("Always approve" fix)

final class ApprovalOverridesGateTests: XCTestCase {

    private func call(_ name: String, command: String? = nil) -> ParsedToolCall {
        var args: [String: LFJSONValue] = [:]
        if let command { args["command"] = .string(command) }
        return ParsedToolCall(name: name, arguments: .object(args), index: 0)
    }

    func testLiveEditOverrideAutoApprovesWritesMidRun() {
        let overrides = ApprovalOverrides()
        let gate = PermissionGate(workspace: Workspace(root: URL(fileURLWithPath: "/tmp/w")))
        // Before the override: edits ask.
        XCTAssertEqual(gate.decision(for: call("edit_file"), risk: .write), .needsApproval)
        // After tapping "Always approve": same gate value now auto-approves.
        overrides.allowEdits()
        let liveGate = PermissionGate(workspace: gate.workspace, overrides: overrides)
        XCTAssertEqual(liveGate.decision(for: call("edit_file"), risk: .write), .auto)
    }

    func testLiveCommandOverrideStillRespectsCommandPolicy() {
        let overrides = ApprovalOverrides()
        overrides.allowCommands()
        let gate = PermissionGate(workspace: Workspace(root: URL(fileURLWithPath: "/tmp/w")), overrides: overrides)
        // A policy-safe command auto-approves.
        XCTAssertEqual(gate.decision(for: call("run_command", command: "ls"), risk: .execute), .auto)
        // A dangerous command STILL asks — the override never bypasses the
        // allowlist policy (no blanket shell bypass).
        XCTAssertEqual(gate.decision(for: call("run_command", command: "rm -rf /"), risk: .execute), .needsApproval)
    }

    func testOverridesDoNotAffectReadsOrUnknownRisk() {
        let overrides = ApprovalOverrides()
        overrides.allowEdits()
        overrides.allowCommands()
        let gate = PermissionGate(workspace: Workspace(root: URL(fileURLWithPath: "/tmp/w")), overrides: overrides)
        XCTAssertEqual(gate.decision(for: call("read_file"), risk: .read), .auto)
        XCTAssertEqual(gate.decision(for: call("mystery"), risk: .none), .needsApproval)
    }
}
