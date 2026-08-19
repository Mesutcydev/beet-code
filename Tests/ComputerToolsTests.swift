import XCTest
@testable import BeetCode

/// Computer-use unit tests. Everything here is hermetic: key mapping, AX-tree
/// rendering, argument accessors, registration. Posting real CGEvents or
/// reading a live AX tree is exercised manually (and would be hostile in CI).
final class ComputerToolsTests: XCTestCase {

    // MARK: Key mapping

    func testNamedKeysResolve() {
        XCTAssertEqual(ComputerKey.keyCode(for: "return"), 36)
        XCTAssertEqual(ComputerKey.keyCode(for: "Enter"), 36) // case-insensitive
        XCTAssertEqual(ComputerKey.keyCode(for: "escape"), 53)
        XCTAssertEqual(ComputerKey.keyCode(for: "esc"), 53)
        XCTAssertEqual(ComputerKey.keyCode(for: "tab"), 48)
        XCTAssertEqual(ComputerKey.keyCode(for: "left"), 123)
        XCTAssertEqual(ComputerKey.keyCode(for: "f5"), 96)
        XCTAssertEqual(ComputerKey.keyCode(for: "page_down"), 121)
    }

    func testSingleCharacterKeysResolve() {
        XCTAssertEqual(ComputerKey.keyCode(for: "a"), 0)
        XCTAssertEqual(ComputerKey.keyCode(for: "S"), 1)
        XCTAssertEqual(ComputerKey.keyCode(for: "0"), 29)
    }

    func testUnknownKeysReturnNil() {
        XCTAssertNil(ComputerKey.keyCode(for: "hyper"))
        XCTAssertNil(ComputerKey.keyCode(for: "ab")) // multi-char, not a named key
        XCTAssertNil(ComputerKey.keyCode(for: ""))
    }

    func testModifierMapping() {
        XCTAssertEqual(ComputerKey.modifiers(for: ["cmd"]), .maskCommand)
        XCTAssertEqual(ComputerKey.modifiers(for: ["command", "shift"]),
                       [.maskCommand, .maskShift])
        XCTAssertEqual(ComputerKey.modifiers(for: ["opt"]), .maskAlternate)
        XCTAssertEqual(ComputerKey.modifiers(for: ["ctrl"]), .maskControl)
        XCTAssertEqual(ComputerKey.modifiers(for: ["bogus"]), [])
    }

    // MARK: AX tree rendering

    func testRenderFormatsNodesWithCoordinates() {
        let nodes = [
            AXNodeInfo(depth: 0, role: "AXWindow", label: "Document", value: "",
                       frame: CGRect(x: 100, y: 50, width: 800, height: 600), enabled: true),
            AXNodeInfo(depth: 1, role: "AXButton", label: "Save", value: "",
                       frame: CGRect(x: 808, y: 606, width: 64, height: 28), enabled: true),
        ]
        let text = AXTreeWalker.render(nodes)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("AXWindow \"Document\""))
        XCTAssertTrue(lines[1].hasPrefix("  AXButton \"Save\""), "children indent by depth")
        // Center point of the frame, top-left origin — what computer_click takes.
        XCTAssertTrue(lines[1].contains("at (840,620)"))
        XCTAssertTrue(lines[1].contains("64×28"))
    }

    func testRenderShowsValueWhenDifferentFromLabel() {
        let node = AXNodeInfo(depth: 0, role: "AXTextField", label: "Search",
                              value: "beet", frame: .zero, enabled: true)
        let text = AXTreeWalker.render([node])
        XCTAssertTrue(text.contains("value \"beet\""))
        XCTAssertFalse(text.contains("at ("), "zero frame renders no coordinates")
    }

    func testRenderMarksDisabledElements() {
        let node = AXNodeInfo(depth: 0, role: "AXButton", label: "Go",
                              value: "", frame: .zero, enabled: false)
        XCTAssertTrue(AXTreeWalker.render([node]).contains("[disabled]"))
    }

    func testRenderEmptyTreeHasPlaceholder() {
        XCTAssertEqual(AXTreeWalker.render([]), "(no accessible elements found)")
    }

    // MARK: strings accessor

    func testStringsAccessorReadsArraysAndSingleStrings() {
        let arrayCall = ToolParser.parse(
            #"```tool {"name":"computer_key","arguments":{"key":"s","modifiers":["cmd","shift"]}} ```"#)
            .first
        XCTAssertEqual(arrayCall?.strings("modifiers"), ["cmd", "shift"])

        let singleCall = ToolParser.parse(
            #"```tool {"name":"computer_key","arguments":{"key":"s","modifiers":"cmd"}} ```"#)
            .first
        XCTAssertEqual(singleCall?.strings("modifiers"), ["cmd"],
                       "a bare string is a one-element array — models emit both")

        XCTAssertEqual(arrayCall?.strings("missing"), [])
    }

    // MARK: Registration

    @MainActor
    func testComputerToolsRegisteredWithCorrectRiskClasses() {
        let tools = Dictionary(
            uniqueKeysWithValues: AgentSessionController.defaultTools.map { ($0.name, $0.risk) })
        // Observation: auto-approved reads.
        XCTAssertEqual(tools["computer_status"], .read)
        XCTAssertEqual(tools["computer_ui_tree"], .read)
        XCTAssertEqual(tools["computer_screenshot"], .read)
        // Input: approval-gated, always.
        XCTAssertEqual(tools["computer_click"], .execute)
        XCTAssertEqual(tools["computer_type"], .execute)
        XCTAssertEqual(tools["computer_key"], .execute)
        XCTAssertEqual(tools["computer_scroll"], .execute)
    }

    @MainActor
    func testComputerToolSchemasAreValidJSON() {
        for tool in AgentSessionController.defaultTools where tool.name.hasPrefix("computer_") {
            let data = Data(tool.schemaText.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "\(tool.name) schemaText must be valid JSON")
        }
    }
}
