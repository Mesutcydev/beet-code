import Foundation
import XCTest
@testable import BeetCode

/// Phase 5 — Semantic enrichment. The stub provider is a test seam (mocks
/// belong in tests); the live sourcekit-lsp test runs the REAL server and
/// skips honestly when the toolchain lacks it.
final class SemanticCoreTests: XCTestCase {

    private final class StubProvider: SemanticProvider, @unchecked Sendable {
        let sourceLabel = "stub-lsp"
        var available = true
        var resolved: [ResolvedSymbol] = []
        func isAvailable() async -> Bool { available }
        func documentSymbols(path: String, content: String, language: String) async throws -> [ResolvedSymbol] {
            resolved
        }
    }

    private let source = """
    import Foundation
    struct Widget {
        func render() {}
    }
    """

    private func graphWithSource() throws -> (SymbolGraph, ParsedFile) {
        let graph = try SymbolGraph(store: SQLiteStore(url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        let file = SourceFile(path: "Widget.swift", content: source,
                              contentHash: ContentDigest.sha256Hex(source))
        let parsed = ParserRegistry.parse(file: file)!
        try graph.upsertFile(parsed)
        return (graph, parsed)
    }

    func testEnrichmentUpgradesMatchingSymbolsOnly() async throws {
        let (graph, parsed) = try graphWithSource()
        let stub = StubProvider()
        stub.resolved = [
            ResolvedSymbol(name: "Widget", kind: "struct", line: 2, containerName: nil),
            // Wrong line — outside tolerance; must NOT match.
            ResolvedSymbol(name: "render", kind: "method", line: 40, containerName: "Widget"),
        ]
        let report = await SemanticEnricher().enrich(
            graph: graph, provider: stub,
            files: [(parsed, "/tmp/Widget.swift", source)])

        XCTAssertEqual(report.filesChecked, 1)
        XCTAssertEqual(report.symbolsUpgraded, 1)
        let widget = try graph.findSymbols(named: "Widget").first!
        XCTAssertEqual(widget.source, "stub-lsp")
        let render = try graph.findSymbols(named: "render").first!
        XCTAssertEqual(render.source, "syntacticParser") // untouched
    }

    func testUnavailableProviderChangesNothing() async throws {
        let (graph, parsed) = try graphWithSource()
        let stub = StubProvider()
        stub.available = false
        let report = await SemanticEnricher().enrich(
            graph: graph, provider: stub,
            files: [(parsed, "/tmp/Widget.swift", source)])
        XCTAssertEqual(report.filesUnavailable, 1)
        let widget = try graph.findSymbols(named: "Widget").first!
        XCTAssertEqual(widget.source, "syntacticParser")
    }

    func testSyntacticFallbackSurvivesProviderFailure() async throws {
        let (graph, parsed) = try graphWithSource()
        struct FailingProvider: SemanticProvider {
            let sourceLabel = "failing"
            func isAvailable() async -> Bool { true }
            func documentSymbols(path: String, content: String, language: String) async throws -> [ResolvedSymbol] {
                throw CocoaError(.coderReadCorrupt)
            }
        }
        let report = await SemanticEnricher().enrich(
            graph: graph, provider: FailingProvider(),
            files: [(parsed, "/tmp/Widget.swift", source)])
        XCTAssertEqual(report.filesUnavailable, 1)
        // Graph still holds the full syntactic index — degradation, not loss.
        XCTAssertEqual(try graph.findSymbols(named: "Widget").count, 1)
    }

    func testSourceKitAvailabilityProbeIsHonest() async {
        let provider = SourceKitLSPProvider()
        let available = await provider.isAvailable()
        // Probe truth equals binary presence — no assumption either way.
        XCTAssertEqual(available, SourceKitLSPProvider.locateBinary() != nil)
    }

    func testLiveSourceKitRoundTrip() async throws {
        try XCTSkipUnless(SourceKitLSPProvider.locateBinary() != nil,
                          "sourcekit-lsp not installed in this toolchain")
        let ws = TempWorkspace()
        let fileURL = ws.write(source, to: "Widget.swift")
        let provider = SourceKitLSPProvider()
        let symbols = try await provider.documentSymbols(
            path: fileURL.path, content: source, language: "swift")
        XCTAssertTrue(symbols.contains { $0.name == "Widget" },
                      "live LSP must see the struct: got \(symbols)")
        XCTAssertTrue(symbols.contains { $0.name == "render" })
    }
}
