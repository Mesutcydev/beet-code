import XCTest
@testable import BeetCode

@MainActor
final class IntentComposerTests: XCTestCase {

    func testEmptySelectionProducesNoPreamble() {
        let model = LatticeModel()
        XCTAssertNil(model.contextPreamble(draft: "hello"))
        XCTAssertTrue(model.isEmpty)
    }

    func testToggleIsBinaryAndDeduped() {
        let model = LatticeModel()
        model.toggle(.research)
        model.toggle(.research)
        model.toggle(.research)
        XCTAssertEqual(model.orderedRoles, [.research])
        model.toggle(.research)
        XCTAssertTrue(model.roles.isEmpty)
    }

    func testRolesEmitInFixedPipelineOrder() {
        let model = LatticeModel()
        model.toggle(.verify)
        model.toggle(.research)
        model.toggle(.build)
        XCTAssertEqual(model.orderedRoles, [.research, .build, .verify])
        let text = model.contextPreamble()
        XCTAssertNotNil(text)
        let research = text!.range(of: "- Research:")!
        let build = text!.range(of: "- Build:")!
        let verify = text!.range(of: "- Verify:")!
        XCTAssertLessThan(research.lowerBound, build.lowerBound)
        XCTAssertLessThan(build.lowerBound, verify.lowerBound)
    }

    func testRoleInstructionNeverDuplicates() {
        let model = LatticeModel()
        model.apply(LatticeModel.presets.first { $0.id == "research" }!)
        let text = model.contextPreamble()!
        let count = text.components(separatedBy: "- Research:").count - 1
        XCTAssertEqual(count, 1)
    }

    func testShipPresetIsBuildThenVerify() {
        let model = LatticeModel()
        model.apply(LatticeModel.presets.first { $0.id == "ship" }!)
        XCTAssertEqual(model.orderedRoles, [.build, .verify])
        XCTAssertTrue(model.focuses.isEmpty)
    }

    func testFocusWithoutResolverIsHonest() {
        let model = LatticeModel()
        model.toggle(.docs)
        let text = model.contextPreamble(workspace: nil)
        XCTAssertTrue(text!.contains("@docs — (nothing found)."))
        XCTAssertFalse(text!.contains("--- Context ---"))
    }

    func testFilesFocusUsesAttachmentNames() {
        let model = LatticeModel()
        model.toggle(.files)
        let attachment = ComposerAttachment(url: URL(fileURLWithPath: "/tmp/Foo.swift"))
        let text = model.contextPreamble(attachments: [attachment])
        XCTAssertTrue(text!.contains("@files — attached: Foo.swift."))
    }

    func testPreambleUsesIntentHeadingNotLatticeFence() {
        let model = LatticeModel()
        model.toggle(.build)
        let text = model.contextPreamble()!
        XCTAssertTrue(text.hasPrefix("Intent for this turn:"))
        XCTAssertFalse(text.contains("[lattice]"))
        XCTAssertFalse(text.contains("weight"))
    }

    func testEstimateTokensIsCharsOverFour() {
        XCTAssertEqual(LatticeEngine.estimateTokens(""), 0)
        XCTAssertEqual(LatticeEngine.estimateTokens("abcd"), 1)
        XCTAssertEqual(LatticeEngine.estimateTokens("abcdefgh"), 2)
    }

    func testFocusPrunedWhenWindowTiny() {
        let model = LatticeModel()
        model.toggle(.build)
        model.toggle(.codebase)
        // Tiny window forces the focus content (if any) to drop; role stays.
        let result = model.compose(draft: String(repeating: "x", count: 200), contextWindow: 80)
        XCTAssertNotNil(result.text)
        XCTAssertTrue(result.text!.contains("- Build:"))
    }
}
