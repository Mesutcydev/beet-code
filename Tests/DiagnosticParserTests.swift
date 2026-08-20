import XCTest
@testable import BeetCode

final class DiagnosticParserTests: XCTestCase {

    func testSwiftErrorParsed() {
        let output = """
        /Users/me/Project/Sources/App.swift:12:34: error: cannot find 'foo' in scope
        """
        let diagnostics = DiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].file, "/Users/me/Project/Sources/App.swift")
        XCTAssertEqual(diagnostics[0].line, 12)
        XCTAssertEqual(diagnostics[0].column, 34)
        XCTAssertEqual(diagnostics[0].message, "cannot find 'foo' in scope")
    }

    func testWarningAndNoteParsed() {
        let output = """
        Sources/App.swift:5:1: warning: variable 'x' was never used
        Sources/App.swift:5:1: note: did you mean 'y'?
        """
        let diagnostics = DiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.map(\.severity), [.warning, .note])
    }

    func testMultipleFilesAndLines() {
        let output = """
        Sources/A.swift:1:1: error: first error
        Sources/B.swift:2:3: error: second error
        Sources/A.swift:10:1: warning: a warning
        """
        let diagnostics = DiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertEqual(Set(diagnostics.map(\.file)).count, 2)
        XCTAssertEqual(diagnostics.filter { $0.severity == .error }.count, 2)
    }

    func testMalformedLinesAreIgnored() {
        let output = """
        Build complete! (2.0s)
        note: run in release mode
        Sources/A.swift:not-a-line: error: malformed
        Sources/A.swift:1:2: error:
        """
        let diagnostics = DiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1, "only the well-formed line parses")
        XCTAssertEqual(diagnostics[0].message, "")
    }

    func testRenderGroupsBySeverity() {
        let diagnostics = [
            Diagnostic(file: "a.swift", line: 1, column: 2, severity: .error, message: "bad"),
            Diagnostic(file: "a.swift", line: 3, column: 4, severity: .warning, message: "meh"),
            Diagnostic(file: "b.swift", line: 5, column: 6, severity: .error, message: "worse"),
        ]
        let rendered = DiagnosticParser.render(diagnostics)
        XCTAssertTrue(rendered.contains("2 error(s)"), rendered)
        XCTAssertTrue(rendered.contains("1 warning(s)"), rendered)
        XCTAssertTrue(rendered.contains("a.swift:1:2: bad"), rendered)
    }

    func testRenderEmpty() {
        XCTAssertEqual(DiagnosticParser.render([]), "Checks completed with no compiler diagnostics.")
    }

    func testXcodebuildFormat() {
        let output = """
        /Users/me/Project/main.swift:42:9: error: type 'X' has no member 'y'
        ** BUILD FAILED **
        """
        let diagnostics = DiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].line, 42)
    }

    func testBuildDiagnosticsToolRender() {
        let result = CommandResult(
            exitCode: 1,
            timedOut: false,
            output: "Sources/A.swift:1:1: error: boom\n** BUILD FAILED **")
        let rendered = BuildDiagnosticsTool.render(result)
        XCTAssertTrue(rendered.contains("1 error(s)"), rendered)
        XCTAssertTrue(rendered.contains("exit status 1"), rendered)
        XCTAssertTrue(rendered.contains("raw output:"), rendered)
    }

    func testBuildDiagnosticsToolTimeout() {
        let result = CommandResult(exitCode: -1, timedOut: true, output: "")
        let rendered = BuildDiagnosticsTool.render(result)
        XCTAssertTrue(rendered.contains("timed out"), rendered)
    }
}
