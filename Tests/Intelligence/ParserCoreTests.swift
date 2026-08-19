import Foundation
import XCTest
@testable import BeetCode

/// Phase 2 — Parser Core. Fixture sources with known expected symbols;
/// assertions cover declarations, ranges, nesting, imports, relationships,
/// call candidates, stable IDs, and failure resilience. No mocks.
final class ParserCoreTests: XCTestCase {

    private func parse(_ source: String, path: String = "Sources/App/Thing.swift") -> ParsedFile {
        let hash = ContentDigest.sha256Hex(source)
        let file = SourceFile(path: path, content: source, contentHash: hash)
        guard let parsed = ParserRegistry.parse(file: file) else {
            XCTFail("Swift adapter missing")
            return ParsedFile(path: path, contentHash: hash, language: "swift",
                              symbols: [], imports: [], references: [])
        }
        return parsed
    }

    // MARK: Fixture: realistic Swift file

    private let fixture = """
    import Foundation
    import CryptoKit
    @testable import BeetCode

    /// Doc comment with fake code: func notReal() {}
    // Another fake: struct Nope {}
    /* Block fake: class AlsoNope {} */

    final class SessionController: ObservableObject, SessionManaging {
        private let store: SessionStore
        var activeSession: Session?

        init(store: SessionStore) {
            self.store = store
        }

        func reconnect() async throws {
            let session = loadSession()
            try await session.resume()
            await store.persist(session)
        }

        static func makeDefault() -> SessionController {
            SessionController(store: SessionStore())
        }
    }

    struct RemoteSession {
        let identifier: UUID
    }

    extension SessionController {
        func handleForeground() {
            reconnectTask()
        }
    }

    protocol SessionManaging {
        func resume()
    }
    """

    func testExtractsTopLevelTypes() {
        let parsed = parse(fixture)
        let names = parsed.symbols.filter { $0.containerID == nil }.map(\.name)
        XCTAssertTrue(names.contains("SessionController"))
        XCTAssertTrue(names.contains("RemoteSession"))
        XCTAssertTrue(names.contains("SessionManaging"))
        // The extension is its own top-level symbol.
        XCTAssertTrue(parsed.symbols.contains { $0.kind == .extension && $0.name == "SessionController" })
    }

    func testCommentsDoNotProduceSymbols() {
        let parsed = parse(fixture)
        let names = parsed.symbols.map(\.name)
        XCTAssertFalse(names.contains("notReal"))
        XCTAssertFalse(names.contains("Nope"))
        XCTAssertFalse(names.contains("AlsoNope"))
    }

    func testMethodsAndKinds() {
        let parsed = parse(fixture)
        let reconnect = parsed.symbols.first { $0.name == "reconnect" }
        XCTAssertNotNil(reconnect)
        XCTAssertEqual(reconnect?.kind, .function)
        XCTAssertTrue(reconnect?.modifiers.contains("async") == true)
        XCTAssertTrue(reconnect?.modifiers.contains("throws") == true)

        let makeDefault = parsed.symbols.first { $0.name == "makeDefault" }
        XCTAssertTrue(makeDefault?.modifiers.contains("static") == true)

        let store = parsed.symbols.first { $0.name == "store" }
        XCTAssertEqual(store?.kind, .property)
        XCTAssertEqual(store?.access, "private")
    }

    func testContainerNesting() {
        let parsed = parse(fixture)
        let reconnect = parsed.symbols.first { $0.name == "reconnect" }
        let controller = parsed.symbols.first { $0.name == "SessionController" && $0.kind == .class }
        XCTAssertNotNil(reconnect?.containerID)
        XCTAssertEqual(reconnect?.containerID, controller?.symbolID)

        let handleForeground = parsed.symbols.first { $0.name == "handleForeground" }
        let ext = parsed.symbols.first { $0.kind == .extension }
        XCTAssertEqual(handleForeground?.containerID, ext?.symbolID)
    }

    func testSourceRangesSpanDeclarationBodies() {
        let parsed = parse(fixture)
        let reconnect = parsed.symbols.first { $0.name == "reconnect" }
        XCTAssertNotNil(reconnect)
        XCTAssertGreaterThan(reconnect!.range.endLine, reconnect!.range.startLine)
        // Body lines: func reconnect() async throws { ... } spans 4 lines.
        XCTAssertEqual(reconnect!.range.endLine - reconnect!.range.startLine, 4)
    }

    func testImports() {
        let parsed = parse(fixture)
        XCTAssertEqual(parsed.imports.map(\.module), ["Foundation", "CryptoKit", "BeetCode"])
    }

    func testTypeRelationships() {
        let parsed = parse(fixture)
        let controller = parsed.symbols.first { $0.name == "SessionController" && $0.kind == .class }
        XCTAssertEqual(controller?.typeRelationships, ["ObservableObject", "SessionManaging"])
    }

    func testCallCandidatesExcludeDeclarationLines() {
        let parsed = parse(fixture)
        let calls = parsed.references.filter { $0.kind == .call }.map(\.name)
        XCTAssertTrue(calls.contains("loadSession"))
        XCTAssertTrue(calls.contains("resume"))
        XCTAssertTrue(calls.contains("persist"))
        XCTAssertTrue(calls.contains("reconnectTask"))
        // Declaration names must not appear as call candidates on their own lines.
        let reconnectDeclLine = parsed.symbols.first { $0.name == "reconnect" }?.range.startLine
        let callsOnDeclLine = parsed.references.filter { $0.line == reconnectDeclLine && $0.kind == .call }
        XCTAssertTrue(callsOnDeclLine.isEmpty)
    }

    func testStableSymbolIdentityAcrossUnrelatedEdits() {
        let first = parse(fixture)
        // Unrelated edit: comment added at the very end of the file.
        let edited = fixture + "\n// trailing comment\n"
        let second = parse(edited)
        let idFirst = first.symbols.first { $0.name == "reconnect" }?.symbolID
        let idSecond = second.symbols.first { $0.name == "reconnect" }?.symbolID
        XCTAssertNotNil(idFirst)
        XCTAssertEqual(idFirst, idSecond)
        XCTAssertTrue(idFirst?.hasPrefix("sym_") == true)
    }

    func testDescriptorFormat() {
        let parsed = parse(fixture)
        let reconnect = parsed.symbols.first { $0.name == "reconnect" }
        XCTAssertEqual(
            reconnect?.descriptor,
            "swift:Sources/App/Thing.swift:SessionController/reconnect()")
    }

    func testTestMethodClassification() {
        let source = """
        final class ReconnectTests: XCTestCase {
            func testResumeExistingSession() {
                XCTAssertTrue(true)
            }
            func helper() {}
        }
        struct Utilities {
            func testConnection() {}
        }
        """
        let parsed = parse(source, path: "Tests/ReconnectTests.swift")
        let testMethod = parsed.symbols.first { $0.name == "testResumeExistingSession" }
        XCTAssertEqual(testMethod?.kind, .test)
        XCTAssertEqual(parsed.symbols.first { $0.name == "helper" }?.kind, .function)
        // testConnection is not inside a *Tests container → stays a function.
        XCTAssertEqual(parsed.symbols.first { $0.name == "testConnection" }?.kind, .function)
    }

    // MARK: Failure resilience

    func testGarbageInputNeverCrashesAndYieldsPartialResults() {
        let garbage = """
        func complete() {}
        }}} {{{
        struct Unterminated {
            func dangling( {
        "unterminated string
        /* unterminated comment
        func afterGarbage() {}
        """
        let parsed = parse(garbage, path: "Garbage.swift")
        // Must not crash; complete() was parsed before the damage.
        XCTAssertTrue(parsed.symbols.contains { $0.name == "complete" })
        // No exception, bounded output, nothing fabricated.
        XCTAssertLessThan(parsed.symbols.count, 20)
    }

    func testEmptyFileParsesEmpty() {
        let parsed = parse("", path: "Empty.swift")
        XCTAssertTrue(parsed.symbols.isEmpty)
        XCTAssertTrue(parsed.imports.isEmpty)
        XCTAssertTrue(parsed.references.isEmpty)
    }

    func testUnsupportedExtensionReturnsNilNotEmptyParse() {
        let file = SourceFile(path: "data.bin", content: "x", contentHash: "h")
        XCTAssertNil(ParserRegistry.parse(file: file))
    }

    func testStringLiteralBracesDoNotCorruptNesting() {
        let source = """
        struct Render {
            func draw() {
                let template = "value: {\\(count)}"
                print(template)
            }
            var computed: Int { 42 }
        }
        """
        let parsed = parse(source, path: "Render.swift")
        let draw = parsed.symbols.first { $0.name == "draw" }
        let computed = parsed.symbols.first { $0.name == "computed" }
        XCTAssertEqual(draw?.containerID, parsed.symbols.first { $0.name == "Render" }?.symbolID)
        // Single-line computed property must not swallow following symbols.
        XCTAssertEqual(computed?.range.startLine, computed?.range.endLine)
    }

    func testMultilineCommentNesting() {
        let source = """
        /* outer
           /* inner */
           still comment: struct Fake {}
        */
        struct Real {}
        """
        let parsed = parse(source, path: "Nested.swift")
        XCTAssertTrue(parsed.symbols.contains { $0.name == "Real" })
        XCTAssertFalse(parsed.symbols.contains { $0.name == "Fake" })
    }
}
