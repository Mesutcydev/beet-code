import XCTest
@testable import BeetCode

final class ReasoningTests: XCTestCase {

    func testExtractingThinking() {
        let text = "Let me think. <think>The build fails because X.</think> I'll fix it. <think>Also Y.</think>"
        let extracted = PromptBuilder.extractingThinking(text)
        XCTAssertEqual(extracted, "The build fails because X.\n\nAlso Y.")
        XCTAssertNil(PromptBuilder.extractingThinking("no thinking here"))
        XCTAssertNil(PromptBuilder.extractingThinking("<think>unterminated"))
    }

    func testStrippingStillRemovesThinkBlocks() {
        let stripped = PromptBuilder.strippingThinking("<think>hidden</think>visible")
        XCTAssertEqual(stripped, "visible")
    }

    func testNumberAccessor() {
        let call = ParsedToolCall(name: "t", arguments: .object(["x": .number(0.5)]), index: 0)
        XCTAssertEqual(call.number("x"), 0.5)
        let stringy = ParsedToolCall(name: "t", arguments: .object(["x": .string("0.75")]), index: 0)
        XCTAssertEqual(stringy.number("x"), 0.75)
        XCTAssertNil(stringy.number("missing"))
    }

    func testSummarizeHandlesArgentBanner() {
        let withBanner = "NOTE: An update is available\n{\"devices\":[{\"platform\":\"ios\",\"name\":\"iPhone\"}]}\n"
        let summary = Summarize.argentOutput(withBanner, tool: "list-devices")
        XCTAssertTrue(summary.contains("iPhone"), summary)
        XCTAssertFalse(summary.contains("NOTE"), summary)
    }

    func testSummarizeFallsBackToRawText() {
        let summary = Summarize.argentOutput("Booted iPhone 17 Pro", tool: "boot-device")
        XCTAssertTrue(summary.contains("Booted"), summary)
        XCTAssertEqual(Summarize.argentOutput("", tool: "x"), "(x returned no output)")
    }

    func testComposerFlowPresets() {
        XCTAssertEqual(ComposerFlow.allCases.count, 4)
        for flow in ComposerFlow.allCases {
            XCTAssertGreaterThan(flow.colors.count, 1)
            XCTAssertGreaterThan(flow.cycleSeconds, 0)
        }
    }
}