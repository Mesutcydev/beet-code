import Foundation
import XCTest
@testable import BeetCode

/// Phase 22 — SDK facade + CLI routing against a real workspace.
final class PublicSDKTests: XCTestCase {

    private var retained: [TempWorkspace] = []
    private var workspace: TempWorkspace!

    override func setUp() async throws {
        let ws = TempWorkspace()
        retained.append(ws)
        workspace = ws
        ws.write("""
        final class AuthService {
            func refreshToken() {
                persistSession()
            }

            private func persistSession() {
            }
        }
        """, to: "Sources/Auth/AuthService.swift")
        ws.write("""
        final class SessionManager {
            func resume() {
                AuthService().refreshToken()
            }
        }
        """, to: "Sources/Auth/SessionManager.swift")

        let storeDir = TempWorkspace()
        retained.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        WorkspaceSnapshotStore.shared.overrideDirectory =
            storeDir.url.appendingPathComponent("snapshots")
    }

    // MARK: SDK facade

    func testFacadeEndToEnd() async throws {
        let intel = WorkspaceIntelligence(workspaceRoot: workspace.url)

        let stats = try await intel.index()
        XCTAssertEqual(stats.parsed, 2)

        let overview = try intel.overview()
        XCTAssertTrue(overview.contains("swift"), overview)

        let packet = try intel.context(for: "how does refreshToken work")
        XCTAssertTrue(packet.symbols.contains { $0.name == "refreshToken" })

        let hits = try intel.searchSymbols(matching: "session")
        XCTAssertTrue(hits.contains { $0.name == "SessionManager" })

        let impact = try intel.impact(ofSymbol: "refreshToken")
        XCTAssertTrue(impact.directCallers.contains { $0.contains("resume") })

        // Knowledge lifecycle through the facade.
        let rejected = try intel.proposeKnowledge(
            kind: .decision, scope: "Auth", statement: "tokens live in memory only")
        guard case .rejected = rejected else {
            return XCTFail("evidence-less agent claim must be rejected")
        }
        let committed = try intel.proposeKnowledge(
            kind: .decision, scope: "Auth", statement: "tokens live in memory only",
            evidencePaths: ["Sources/Auth/AuthService.swift"])
        guard case .committed = committed else {
            return XCTFail("evidenced claim must commit, got \(committed)")
        }

        // No working state yet → honest nil.
        XCTAssertNil(try intel.handoff())

        let verifier = try intel.verifier()
        guard case .verified = try verifier.symbolExists("refreshToken") else {
            return XCTFail("refreshToken must verify")
        }
    }

    // MARK: CLI

    private func runCLI(_ args: [String]) async -> (Int32, String) {
        var output: [String] = []
        let code = await IntelligenceCLI.run(arguments: args) { output.append($0) }
        return (code, output.joined(separator: "\n"))
    }

    func testCLIUsageAndUnknownCommand() async {
        let (codeNoArgs, outNoArgs) = await runCLI([])
        XCTAssertEqual(codeNoArgs, 2)
        XCTAssertTrue(outNoArgs.contains("beetcode intel"))

        let (codeBad, _) = await runCLI(["frobnicate"])
        XCTAssertEqual(codeBad, 2)
    }

    func testCLIIndexOverviewSearchImpactVerify() async {
        let path = workspace.url.path
        let (indexCode, _) = await runCLI(["index", "--workspace", path])
        XCTAssertEqual(indexCode, 0)

        let (overviewCode, overview) = await runCLI(["overview", "--workspace", path])
        XCTAssertEqual(overviewCode, 0)
        XCTAssertTrue(overview.contains("swift"))

        let (_, search) = await runCLI(["search", "session", "--workspace", path])
        XCTAssertTrue(search.contains("SessionManager"), search)

        let (_, impact) = await runCLI(["impact", "refreshToken", "--workspace", path])
        XCTAssertTrue(impact.contains("Direct callers:"), impact)

        let (_, verified) = await runCLI(
            ["verify", "symbol", "refreshToken", "--workspace", path])
        XCTAssertTrue(verified.hasPrefix("VERIFIED"), verified)

        let (_, falsed) = await runCLI(
            ["verify", "call", "resume", "persistSession", "--workspace", path])
        XCTAssertTrue(falsed.hasPrefix("FALSE"), falsed)
    }

    func testCLIContextAndHandoff() async {
        let path = workspace.url.path
        _ = await runCLI(["index", "--workspace", path])

        let (code, context) = await runCLI(
            ["context", "how does refreshToken work", "--workspace", path])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(context.contains("Project Capsule"), context)
        XCTAssertTrue(context.contains("Total:"), context)

        let (_, handoff) = await runCLI(["handoff", "--workspace", path])
        XCTAssertTrue(handoff.contains("no working state"), handoff)
    }
}
