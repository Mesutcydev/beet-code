import Foundation
import XCTest
@testable import BeetCode

/// Phase 15 — Impact analysis. Real graph, real entities, real edges.
final class ImpactAnalyzerTests: XCTestCase {

    private let fixtures: [(path: String, content: String)] = [
        ("Sources/Auth/AuthService.swift", """
        import Foundation

        final class AuthService {
            func refreshToken() {
                persistSession()
            }

            private func persistSession() {
            }
        }
        """),
        ("Sources/Auth/SessionManager.swift", """
        final class SessionManager {
            func resume() {
                AuthService().refreshToken()
            }
        }
        """),
        ("Sources/Auth/LoginView.swift", """
        import SwiftUI

        struct LoginView: View {
            var body: some View {
                Text("Login")
            }
        }
        """),
        ("Sources/Chat/ChatController.swift", """
        final class ChatController {
            func send() {
                SessionManager().resume()
            }

            func openLogin() {
                _ = LoginView()
            }
        }
        """),
        ("Tests/AuthTests/AuthServiceTests.swift", """
        import XCTest

        final class AuthServiceTests: XCTestCase {
            func testRefresh() {
                AuthService().refreshToken()
            }
        }
        """),
    ]

    private func makeAnalyzer() throws -> ImpactAnalyzer {
        let graph = try SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/x"), inMemory: true))
        let entities = try EntityStore(store: SQLiteStore(
            url: URL(fileURLWithPath: "/tmp/y"), inMemory: true))
        for (path, content) in fixtures {
            let source = SourceFile(path: path, content: content, contentHash: "h")
            let parsed = ParserRegistry.parse(file: source)!
            try graph.upsertFile(parsed)
            try entities.replaceEntities(
                forFile: path,
                entities: EntityAdapterRegistry.detect(file: source, parsed: parsed))
        }
        return ImpactAnalyzer(graph: graph, entities: entities)
    }

    func testSymbolImpactReport() throws {
        let report = try makeAnalyzer().impact(ofSymbol: "refreshToken")
        XCTAssertTrue(report.directCallers.contains { $0.contains("resume") },
                      "callers: \(report.directCallers)")
        XCTAssertTrue(report.affectedTests.contains { $0.contains("testRefresh") },
                      "tests: \(report.affectedTests)")
        XCTAssertTrue(report.securityDomains.contains("Authentication"),
                      "domains: \(report.securityDomains)")
        XCTAssertEqual(report.risk, .high) // security domain present
        XCTAssertFalse(report.evidence.isEmpty)
        XCTAssertTrue(report.rendered.contains("Direct callers:"))
        XCTAssertTrue(report.rendered.contains("Risk:\nHigh"))
    }

    func testDependentFeatures() throws {
        let report = try makeAnalyzer().impact(ofSymbol: "refreshToken")
        XCTAssertTrue(report.dependentFeatures.contains("Chat"),
                      "features: \(report.dependentFeatures)")
        XCTAssertFalse(report.dependentFeatures.contains("Auth")) // own feature excluded
    }

    func testFileImpact() throws {
        let report = try makeAnalyzer().impact(ofFile: "Sources/Auth/AuthService.swift")
        XCTAssertTrue(report.directCallers.contains { $0.contains("resume") })
    }

    func testFeatureImpact() throws {
        let report = try makeAnalyzer().impact(ofFeature: "Auth")
        XCTAssertTrue(report.directCallers.contains { $0.contains("openLogin") },
                      "callers: \(report.directCallers)")
        XCTAssertTrue(report.dependentFeatures.contains("Chat"))
    }

    func testUnknownSymbolIsHonest() throws {
        let report = try makeAnalyzer().impact(ofSymbol: "doesNotExist")
        XCTAssertEqual(report.risk, .low)
        XCTAssertTrue(report.directCallers.isEmpty)
        XCTAssertTrue(report.evidence.contains { $0.contains("no symbol named") })
    }

    func testIsolatedSymbolIsLowRisk() throws {
        // `send` has no callers, no tests, no security signals.
        let report = try makeAnalyzer().impact(ofSymbol: "send")
        XCTAssertEqual(report.risk, .low)
        XCTAssertTrue(report.directCallers.isEmpty)
    }

    func testNeverInventsChains() throws {
        // persistSession is only called by refreshToken — the report must
        // not claim Chat depends on it through a chain the graph cannot see.
        let report = try makeAnalyzer().impact(ofSymbol: "persistSession")
        XCTAssertEqual(report.directCallers.count, 1)
        XCTAssertTrue(report.directCallers[0].contains("refreshToken"))
    }
}
