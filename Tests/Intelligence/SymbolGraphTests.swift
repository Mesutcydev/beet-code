import Foundation
import XCTest
@testable import BeetCode

/// Phase 3 — Symbol Graph. Graph contents must originate from real parsed
/// fixtures; every assertion traces to source the parser actually emitted.
final class SymbolGraphTests: XCTestCase {

    private func makeGraph() throws -> SymbolGraph {
        try SymbolGraph(store: SQLiteStore(url: URL(fileURLWithPath: ":memory:"), inMemory: true))
    }

    private func parse(_ source: String, path: String) -> ParsedFile {
        let file = SourceFile(path: path, content: source,
                              contentHash: ContentDigest.sha256Hex(source))
        return ParserRegistry.parse(file: file)!
    }

    // MARK: Fixtures — a small but realistic two-file relationship web

    private let sessionManager = """
    import Foundation

    protocol SessionManaging {
        func activate()
    }

    final class SessionManager: SessionManaging {
        func activate() {}
        func resume() {
            openTransport()
        }
        private func openTransport() {}
    }
    """

    private let controller = """
    import Foundation

    final class SessionController {
        private let manager: SessionManager
        init(manager: SessionManager) { self.manager = manager }
        func handleForeground() {
            manager.resume()
        }
    }
    """

    private let tests = """
    import XCTest

    final class SessionTests: XCTestCase {
        func testResume() {
            let manager = SessionManager()
            manager.resume()
        }
    }
    """

    func testContainsAndFileNodes() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))

        let fileSymbols = try graph.symbols(inFile: "Core/SessionManager.swift")
        XCTAssertEqual(Set(fileSymbols.map(\.name)),
                       ["SessionManaging", "SessionManager", "activate", "resume", "openTransport"])
    }

    func testImportsEdges() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))
        let fileNode = try graph.node(id: "file:Core/Controller.swift")
        let imports = try graph.outgoingEdges(from: fileNode!.id, kind: .imports)
        XCTAssertEqual(imports.map(\.target), ["module:Foundation"])
    }

    func testCallEdgesOnlyWhenUnambiguous() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))

        // manager.resume() resolves to exactly one `resume` symbol.
        let resume = try graph.findSymbols(named: "resume").first { $0.symbolKind == "function" }
        XCTAssertNotNil(resume)
        let callers = try graph.callers(of: resume!.id)
        XCTAssertTrue(callers.contains { $0.name == "handleForeground" })
        XCTAssertTrue(callers.contains { $0.name == "testResume" } == false) // not indexed yet

        // openTransport() is called from resume → callees(resume) contains it.
        let openTransport = try graph.findSymbols(named: "openTransport").first!
        let callees = try graph.callees(of: resume!.id)
        XCTAssertTrue(callees.contains { $0.id == openTransport.id })
    }

    func testAmbiguousCallsProduceNoFabricatedEdge() throws {
        let graph = try makeGraph()
        // Two unrelated `run()` symbols; a third file calls run().
        try graph.upsertFile(parse("struct A { func run() {} }", path: "A.swift"))
        try graph.upsertFile(parse("struct B { func run() {} }", path: "B.swift"))
        try graph.upsertFile(parse("struct C { func go() { runner.run() } }", path: "C.swift"))

        for runSymbol in try graph.findSymbols(named: "run") {
            let callers = try graph.callers(of: runSymbol.id)
            XCTAssertTrue(callers.isEmpty, "ambiguous call must not fabricate an edge")
        }
    }

    func testConformanceAndInheritanceEdges() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        let manager = try graph.findSymbols(named: "SessionManager").first!
        let outgoing = try graph.outgoingEdges(from: manager.id)
        let conforms = outgoing.filter { $0.kind == .conforms }
        XCTAssertEqual(conforms.count, 1)
        let managing = try graph.findSymbols(named: "SessionManaging").first!
        XCTAssertEqual(conforms.first?.target, managing.id)
    }

    func testTestCoverageEdges() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        try graph.upsertFile(parse(tests, path: "Tests/SessionTests.swift"))

        let resume = try graph.findSymbols(named: "resume").first { $0.symbolKind == "function" }!
        let coverage = try graph.incomingEdges(to: resume.id, kind: .tests)
        XCTAssertEqual(coverage.count, 1)
        let testNode = try graph.node(id: coverage.first!.source)
        XCTAssertEqual(testNode?.kind, .test)
        XCTAssertEqual(testNode?.name, "testResume")
    }

    func testFileRemovalCascades() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))
        try graph.removeFile(path: "Core/SessionManager.swift")

        XCTAssertTrue(try graph.symbols(inFile: "Core/SessionManager.swift").isEmpty)
        XCTAssertTrue(try graph.findSymbols(named: "resume").isEmpty)
        // Controller's call edge into the deleted symbol is gone.
        let handle = try graph.findSymbols(named: "handleForeground").first!
        XCTAssertTrue(try graph.outgoingEdges(from: handle.id, kind: .calls).isEmpty)
    }

    func testReupsertKeepsStableIDsAndRefreshesEdges() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        let before = try graph.findSymbols(named: "SessionManager").first!.id

        // Edit: rename the private method and its call site.
        let edited = sessionManager.replacingOccurrences(of: "openTransport", with: "openChannel")
        try graph.upsertFile(parse(edited, path: "Core/SessionManager.swift"))

        XCTAssertEqual(try graph.findSymbols(named: "SessionManager").first!.id, before)
        XCTAssertTrue(try graph.findSymbols(named: "openTransport").isEmpty)
        XCTAssertEqual(try graph.findSymbols(named: "openChannel").count, 1)
        // Old edges must not linger.
        let resume = try graph.findSymbols(named: "resume").first { $0.symbolKind == "function" }!
        let callees = try graph.callees(of: resume.id)
        XCTAssertEqual(callees.map(\.name), ["openChannel"])
    }

    func testImpactNeighborhood() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))
        try graph.upsertFile(parse(tests, path: "Tests/SessionTests.swift"))

        let resume = try graph.findSymbols(named: "resume").first { $0.symbolKind == "function" }!
        let impact = try graph.impactNeighborhood(of: resume.id, depth: 1)
        let names = Set(impact.nodes.map(\.name))
        XCTAssertTrue(names.contains("handleForeground"))
        XCTAssertTrue(names.contains("testResume"))
        // depth 1 must not pull in SessionManager's own container etc.
        XCTAssertFalse(names.contains("SessionController"))
    }

    func testShortestPath() throws {
        let graph = try makeGraph()
        try graph.upsertFile(parse(sessionManager, path: "Core/SessionManager.swift"))
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))

        let handle = try graph.findSymbols(named: "handleForeground").first!
        let resume = try graph.findSymbols(named: "resume").first { $0.symbolKind == "function" }!
        let openTransport = try graph.findSymbols(named: "openTransport").first!

        XCTAssertEqual(try graph.shortestPath(from: handle.id, to: resume.id), [handle.id, resume.id])
        XCTAssertEqual(try graph.shortestPath(from: handle.id, to: openTransport.id),
                       [handle.id, resume.id, openTransport.id])
        XCTAssertNil(try graph.shortestPath(from: openTransport.id, to: handle.id))
    }

    func testGraphGateEdgesTraceToIndexedSource() throws {
        // Gate (spec Phase 3): every edge must carry an origin path and a
        // confidence — there is no API to insert an edge without provenance.
        let graph = try makeGraph()
        try graph.upsertFile(parse(controller, path: "Core/Controller.swift"))
        let handle = try graph.findSymbols(named: "handleForeground").first!
        for edge in try graph.outgoingEdges(from: handle.id) {
            XCTAssertFalse(edge.originPath.isEmpty)
            XCTAssertEqual(edge.confidence, .syntactic)
        }
    }
}
