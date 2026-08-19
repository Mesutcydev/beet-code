import Foundation
import XCTest
@testable import BeetCode

/// Phase 24 — simulated-agent benchmark on a realistic synthetic repo.
/// Deterministic and reproducible; the two exploration policies are
/// documented in AgentBenchmark.swift. A live-model A/B is out of scope for
/// CI and would not be reproducible.
final class AgentBenchmarkTests: XCTestCase {

    private var retained: [TempWorkspace] = []

    /// 60-file repo: an Auth cluster, a Chat cluster, and filler modules.
    private func makeRepo() -> TempWorkspace {
        let ws = TempWorkspace()
        retained.append(ws)
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
        ws.write("""
        final class ChatController {
            func send() {
                SessionManager().resume()
            }
        }
        """, to: "Sources/Chat/ChatController.swift")
        for index in 0..<57 {
            ws.write("""
            final class Filler\(index) {
            func run\(index)() {
            }
            }

            """, to: "Sources/Filler/Module\(index % 6)/Filler\(index).swift")
        }
        return ws
    }

    private func makeIntel(_ ws: TempWorkspace) async throws -> WorkspaceIntelligence {
        let storeDir = TempWorkspace()
        retained.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let intel = WorkspaceIntelligence(
            workspaceRoot: ws.url, snapshotStore: snapshotStore)
        try await intel.index()
        return intel
    }

    func testBenchmarkSuite() async throws {
        let ws = makeRepo()
        let intel = try await makeIntel(ws)
        let files = [
            "Sources/Auth/AuthService.swift",
            "Sources/Auth/SessionManager.swift",
            "Sources/Chat/ChatController.swift",
        ] + (0..<57).map { "Sources/Filler/Module\($0 % 6)/Filler\($0).swift" }

        let tasks = [
            BenchmarkTask(
                name: "fix refreshToken retry",
                text: "fix how refreshToken handles retries",
                targetSymbol: "refreshToken",
                falseClaim: (caller: "resume", callee: "persistSession")),
            BenchmarkTask(
                name: "trace send flow",
                text: "what does ChatController send call",
                targetSymbol: "send",
                falseClaim: (caller: "send", callee: "refreshToken")),
        ]

        var results: [BenchmarkResult] = []
        for task in tasks {
            let a = AgentBenchmark.runWithoutIntelligence(
                task: task, workspaceRoot: ws.url, relativeFiles: files)
            let b = try AgentBenchmark.runWithIntelligence(task: task, intel: intel)
            results.append(BenchmarkResult(
                task: task.name, withoutIntelligence: a, withIntelligence: b))
        }

        print("\n" + AgentBenchmark.render(results))

        for result in results {
            let a = result.withoutIntelligence
            let b = result.withIntelligence
            // Intelligence never explores MORE than grep, and always
            // catches the false structural claim.
            XCTAssertLessThanOrEqual(b.filesOpened, a.filesOpened,
                              "\(result.task): intelligence must not widen exploration")
            XCTAssertEqual(b.uncaughtFalseAssumptions, 0,
                           "\(result.task): claim verification must catch the false claim")
            XCTAssertEqual(a.uncaughtFalseAssumptions, 1)
        }
        // Aggregate across the suite (the spec's success criterion):
        // equivalent work with less redundant exploration. A lucky grep can
        // win a single targeted task on a small repo (see the printed
        // table); the intelligence path wins in aggregate because the
        // capsule cost amortizes and tracing never scans filler.
        let totalA = results.reduce(0) { $0 + $1.withoutIntelligence.inputTokens }
        let totalB = results.reduce(0) { $0 + $1.withIntelligence.inputTokens }
        XCTAssertLessThan(totalB, totalA, "aggregate tokens must favor intelligence")
        let filesA = results.reduce(0) { $0 + $1.withoutIntelligence.filesOpened }
        let filesB = results.reduce(0) { $0 + $1.withIntelligence.filesOpened }
        XCTAssertLessThan(filesB, filesA, "aggregate files opened must favor intelligence")
    }
}
