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

    func testStreamFilterPreservesAnswerStructure() {
        let raw = "- first\n- second\n\n```swift\nlet value = 1\n```"
        let (visible, reasoning) = StreamDisplayFilter.display(raw: raw)
        XCTAssertEqual(visible, raw)
        XCTAssertFalse(reasoning)
    }

    func testAssistantAnswerFormatterRepairsDenseFactBoundaries() {
        let dense = """
        Here are overlooked facts:Berlin Wall's Fall (1989): While celebrated, it also changed policy.Titanic's Logs (1912): Records disagree.Roman Empire's Decline: The causes were complex.
        """
        let formatted = AssistantAnswerFormatter.formattedForDisplay(dense)

        XCTAssertTrue(formatted.contains("facts:\n\nBerlin Wall's Fall"), formatted)
        XCTAssertTrue(formatted.contains("policy.\n\nTitanic's Logs"), formatted)
        XCTAssertTrue(formatted.contains("disagree.\n\nRoman Empire's Decline"), formatted)
    }

    func testAssistantAnswerFormatterDoesNotRewriteCodeFences() {
        let source = "Before:Heading:\n\n```swift\nlet value:Thing = 1\n```"
        let formatted = AssistantAnswerFormatter.formattedForDisplay(source)

        XCTAssertTrue(formatted.contains("Before:\n\nHeading:"), formatted)
        XCTAssertTrue(formatted.contains("```swift\nlet value:Thing = 1\n```"), formatted)
    }

    func testAssistantAnswerFormatterCreatesBlocksForDenseSectionLabels() {
        let dense = "It requires:Chemicals:Pseudoephedrine tablets.Steps:Extract the material."
        let formatted = AssistantAnswerFormatter.formattedForDisplay(dense)

        XCTAssertTrue(formatted.contains("requires:\n\nChemicals:\n\nPseudoephedrine"), formatted)
        XCTAssertTrue(formatted.contains("tablets.\n\nSteps:\n\nExtract"), formatted)
    }

    func testMarkdownDocumentParserPreservesAnswerStructure() {
        let source = "# Result\n\nFirst paragraph.\n\n- one\n- two\n\n---\n\n```swift\nlet x = 1\n```"
        let blocks = MarkdownDocumentParser.blocks(from: source)

        XCTAssertEqual(blocks.map(\.content), [
            .heading(level: 1, text: "Result"),
            .paragraph("First paragraph."),
            .bullets(["one", "two"]),
            .divider,
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    func testAdjacentProviderReasoningDeltasReadAsOneTrace() {
        let raw = "<think>I</think><think> need</think><think> to create</think>"
        XCTAssertEqual(
            PromptBuilder.extractingThinkingIncludingOpen(raw),
            "I need to create")
        XCTAssertFalse(
            StreamDisplayFilter.reasoningText(raw: raw).contains("\n\n"),
            "streamed reasoning fragments must not become one paragraph per token")
    }

    func testModelControlTokensAreHiddenAcrossChatTemplates() {
        let raw = "<|start_header_id|>assistant<|end_header_id|>\nOK<|eot_id|>"
        XCTAssertEqual(PromptBuilder.cleaningGeneratedText(raw), "OK")
        let qwen = "<|im_start|>assistant\nDone<|im_end|>"
        XCTAssertEqual(PromptBuilder.cleaningGeneratedText(qwen), "Done")
    }

    func testExactAnswerContractIsRecognizedWithoutTouchingOrdinaryProse() {
        XCTAssertEqual(
            PromptBuilder.exactRequestedAnswer(in: "Reply with exactly OK."),
            "OK")
        XCTAssertEqual(
            PromptBuilder.exactRequestedAnswer(in: "Respond with exactly READY and nothing else."),
            "READY")
        XCTAssertEqual(
            PromptBuilder.exactRequestedAnswer(in: "Output exactly - first\n- second"),
            "- first\n- second")
        XCTAssertNil(PromptBuilder.exactRequestedAnswer(in: "Please answer normally."))
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
