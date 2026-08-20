import Foundation
import XCTest
@testable import BeetCode

// MARK: - Stream display filter ("thinking thinking…" fix)

final class StreamDisplayFilterTests: XCTestCase {

    func testCompleteThinkBlockHidden() {
        // Complete block with both opening and closing delimiters (some Qwen
        // finetunes use the Chinese '思考' marker instead of <think> tags).
        let raw = "I must consider the file layout. 思考 I am thinking 思考 The fix is here."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "The fix is here.")
        XCTAssertFalse(reasoning)
    }

    func testLoneThinkMarkerKeepsPrecedingTextAndShowsReasoning() {
        // A single marker is ambiguous (the word means "thinking" in ordinary
        // prose): only the tail is hidden, preceding text survives, and the
        // reasoning indicator is on while the block is unclosed.
        let raw = "Working on it. 思考 still pondering the parser"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "Working on it.")
        XCTAssertTrue(reasoning)
    }

    func testThinkMarkerPairAfterVisibleTextStripsThroughClose() {
        // A second pair later in the message is stripped the same way.
        let raw = "思考 hmm 思考 Answer. 思考 more reasoning 思考 Done."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "Done.")
        XCTAssertFalse(reasoning)
    }

    func testOpenThinkBlockShowsReasoningState() {
        let raw = "<think>still pondering…"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "")
        XCTAssertTrue(reasoning)
    }

    func testLiveReasoningTextExtractsOpenAndClosedBlocks() {
        let raw = "<think>first pass</think>Answer <think>still working"
        XCTAssertEqual(StreamDisplayFilter.reasoningText(raw: raw), "first pass\n\nstill working")
    }

    func testLiveReasoningTextExtractsChineseMarkers() {
        let raw = "思考先检查构建 思考答案"
        XCTAssertEqual(StreamDisplayFilter.reasoningText(raw: raw), "先检查构建")
    }

    func testRepetitionFillerIsReasoning() {
        let raw = "thinking thinking thinking thinking thinking"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertTrue(reasoning)
        XCTAssertFalse(visible.contains("thinking"))
    }

    func testRepetitionFollowedByRealTextKeepsText() {
        // When filler is followed by real text, the filler is no longer at the tail,
        // so it should NOT be detected as filler (the real text takes precedence).
        let raw = "thinking thinking thinking thinking\nHere is the answer."
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertFalse(reasoning)
        // The filler at the beginning is preserved since it's not at the tail
        XCTAssertTrue(visible.contains("thinking"))
        XCTAssertTrue(visible.contains("Here is the answer"))
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
