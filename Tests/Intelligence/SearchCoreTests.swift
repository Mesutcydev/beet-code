import Foundation
import XCTest
@testable import BeetCode

/// Phase 6 — Search Core. Real FTS5 index, real queries, no fabricated hits.
final class SearchCoreTests: XCTestCase {

    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(store: SQLiteStore(url: URL(fileURLWithPath: ":memory:"), inMemory: true))
    }

    private func parseAndIndex(_ index: SearchIndex, _ source: String, path: String) throws {
        let file = SourceFile(path: path, content: source,
                              contentHash: ContentDigest.sha256Hex(source))
        let parsed = ParserRegistry.parse(file: file)!
        try index.indexFile(parsed, content: source)
    }

    private let authService = """
    import Foundation
    /// Handles credential refresh and token persistence.
    final class AuthService {
        func refreshToken() {}
        func logout() {}
    }
    """

    private let sessionUI = """
    import SwiftUI
    /// Renders the session list sidebar.
    struct SessionListView: View {
        var body: some View { Text("sessions") }
    }
    """

    func testExactSymbolSearch() throws {
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        try parseAndIndex(index, sessionUI, path: "App/SessionListView.swift")

        let hits = try index.search("refreshToken", kinds: [.symbol])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "Core/AuthService.swift")
    }

    func testLexicalDescriptionSearch() throws {
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        try parseAndIndex(index, sessionUI, path: "App/SessionListView.swift")

        // Natural-language-ish query: terms hit doc comments + names.
        let hits = try index.search("credential token refresh", kinds: [.fileText, .symbol])
        XCTAssertEqual(hits.first?.path, "Core/AuthService.swift")

        let uiHits = try index.search("sidebar sessions", kinds: [.fileText])
        XCTAssertEqual(uiHits.first?.path, "App/SessionListView.swift")
    }

    func testRemovalClearsHits() throws {
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        XCTAssertFalse(try index.search("refreshToken").isEmpty)
        try index.removeFile(path: "Core/AuthService.swift")
        XCTAssertTrue(try index.search("refreshToken").isEmpty)
    }

    func testNoFabricatedHitsForAbsentTerms() throws {
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        XCTAssertTrue(try index.search("kubernetes").isEmpty)
        XCTAssertTrue(try index.search("zzzqqq").isEmpty)
    }

    func testPathSearch() throws {
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        let hits = try index.search("AuthService", kinds: [.path])
        XCTAssertEqual(hits.first?.kind, .path)
    }

    func testRankFusionCombinesListsWithoutScoreMixing() {
        // List A: [x, y, z]; List B: [y, x] — y is 2nd/1st, x is 1st/2nd.
        // RRF: x = 1/61 + 1/62 ≈ 0.0325; y = 1/62 + 1/61 ≈ 0.0325 tie-broken
        // by exact sums; z only in A. Verify ordering mathematics directly.
        let fused = RankFusion.fuse([["x", "y", "z"], ["y", "x"]])
        let scoreX = fused.first { $0.item == "x" }!.score
        let scoreY = fused.first { $0.item == "y" }!.score
        let scoreZ = fused.first { $0.item == "z" }!.score
        XCTAssertEqual(scoreX, 1.0 / 61 + 1.0 / 62, accuracy: 1e-9)
        XCTAssertEqual(scoreY, 1.0 / 62 + 1.0 / 61, accuracy: 1e-9)
        XCTAssertEqual(scoreZ, 1.0 / 63, accuracy: 1e-9)
        XCTAssertLessThan(scoreZ, scoreX)
    }

    func testQueryTokenizationSafety() throws {
        // Injection-ish FTS syntax must not throw or match weirdly.
        let index = try makeIndex()
        try parseAndIndex(index, authService, path: "Core/AuthService.swift")
        XCTAssertNoThrow(try index.search("NEAR/3 (column:*) OR"))
        XCTAssertNoThrow(try index.search("\"\""))
        XCTAssertTrue(try index.search("").isEmpty)
    }
}
