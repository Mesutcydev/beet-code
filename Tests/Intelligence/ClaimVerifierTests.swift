import Foundation
import XCTest
@testable import BeetCode

/// Phase 13 — Claim verification against the live graph.
final class ClaimVerifierTests: XCTestCase {

    private func makeVerifier() throws -> ClaimVerifier {
        let graph = try SymbolGraph(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
        let app = """
        import Foundation
        import CryptoKit
        final class AppState {
            private let coordinator: ReconnectCoordinator
            func handleForeground() { coordinator.resume() }
        }
        final class ReconnectCoordinator {
            func resume() {}
        }
        """
        let manager = """
        import Foundation
        protocol SessionManaging { func activate() }
        final class SessionManager: SessionManaging {
            func activate() {}
        }
        """
        let tests = """
        import XCTest
        final class ReconnectTests: XCTestCase {
            func testResume() { ReconnectCoordinator().resume() }
        }
        """
        for (source, path) in [(app, "App/AppState.swift"),
                               (manager, "Core/SessionManager.swift"),
                               (tests, "Tests/ReconnectTests.swift")] {
            let file = SourceFile(path: path, content: source,
                                  contentHash: ContentDigest.sha256Hex(source))
            try graph.upsertFile(ParserRegistry.parse(file: file)!)
        }
        return ClaimVerifier(graph: graph)
    }

    func testSymbolExists() throws {
        let verifier = try makeVerifier()
        guard case .verified = try verifier.symbolExists("AppState") else {
            return XCTFail()
        }
        guard case .false_ = try verifier.symbolExists("FluxCapacitor") else {
            return XCTFail()
        }
    }

    /// The spec's headline example: "AppState calls SessionManager.resume()"
    /// must come back FALSE with the likely real callers attached.
    func testSpecHeadlineClaim() throws {
        let verifier = try makeVerifier()
        let result = try verifier.callExists(caller: "AppState", callee: "resume")
        guard case .false_(let reason, let suggestions) = result else {
            return XCTFail("expected false, got \(result)")
        }
        XCTAssertTrue(reason.contains("no current call edge"))
        XCTAssertTrue(suggestions.contains { $0.contains("handleForeground") })
        XCTAssertTrue(suggestions.contains { $0.contains("testResume") })
    }

    func testTrueCallVerifies() throws {
        let verifier = try makeVerifier()
        guard case .verified(let evidence) = try verifier.callExists(
            caller: "handleForeground", callee: "resume") else {
            return XCTFail()
        }
        XCTAssertTrue(evidence.contains("AppState.swift"))
    }

    func testUnknownSymbolsAreUnverifiedNotFalse() throws {
        let verifier = try makeVerifier()
        guard case .unverified = try verifier.callExists(
            caller: "Ghost", callee: "resume") else {
            return XCTFail()
        }
    }

    func testConformance() throws {
        let verifier = try makeVerifier()
        guard case .verified = try verifier.conformanceExists(
            type: "SessionManager", protocol: "SessionManaging") else {
            return XCTFail()
        }
        guard case .false_ = try verifier.conformanceExists(
            type: "AppState", protocol: "SessionManaging") else {
            return XCTFail()
        }
    }

    func testDependencyAndFile() throws {
        let verifier = try makeVerifier()
        guard case .verified = try verifier.dependencyExists(
            file: "App/AppState.swift", imports: "CryptoKit") else {
            return XCTFail()
        }
        guard case .false_ = try verifier.dependencyExists(
            file: "App/AppState.swift", imports: "SwiftUI") else {
            return XCTFail()
        }
        guard case .verified = try verifier.fileExists("App/AppState.swift") else {
            return XCTFail()
        }
        guard case .false_ = try verifier.fileExists("App/Nope.swift") else {
            return XCTFail()
        }
    }

    func testTestCoverage() throws {
        let verifier = try makeVerifier()
        guard case .verified(let evidence) = try verifier.testCoversSymbol("resume") else {
            return XCTFail()
        }
        XCTAssertTrue(evidence.contains("testResume"))
        guard case .false_ = try verifier.testCoversSymbol("activate") else {
            return XCTFail()
        }
    }
}
