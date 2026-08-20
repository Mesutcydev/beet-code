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

    func testReasoningAliasesAndOpenBlockAreSupported() {
        let text = "<|thinking|>inspect the project<|/thinking|>Answer <reasoning>check the build</reasoning>"
        XCTAssertEqual(
            PromptBuilder.extractingThinking(text),
            "inspect the project\n\ncheck the build")
        XCTAssertEqual(PromptBuilder.strippingThinking(text), "Answer")
        XCTAssertEqual(
            PromptBuilder.extractingThinkingIncludingOpen("Answer <thinking>still working"),
            "still working")
        XCTAssertTrue(PromptBuilder.hasOpenThinkingBlock("<|assistant_thought|>still working"))
    }

    func testStreamFilterKeepsReasoningSeparateFromAnswer() {
        let raw = "<thinking>inspect the project</thinking>Final answer"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, "Final answer")
        XCTAssertFalse(reasoning)
        XCTAssertEqual(StreamDisplayFilter.reasoningText(raw: raw), "inspect the project")
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
