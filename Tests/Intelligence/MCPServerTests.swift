import Foundation
import XCTest
@testable import BeetCode

/// Phase 21 — MCP server: JSON-RPC handshake, tool schemas, and every tool
/// executed against a real indexed workspace.
final class MCPServerTests: XCTestCase {

    private var retained: [TempWorkspace] = []
    private var workspace: TempWorkspace!
    private var server: IntelligenceMCPServer!

    override func setUp() async throws {
        let ws = TempWorkspace()
        retained.append(ws)
        workspace = ws
        ws.write("""
        import Foundation

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
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let identity = WorkspaceIdentity.resolve(root: ws.url)
        let engine = IndexEngine(
            identity: identity,
            graph: try SymbolGraph(store: SQLiteStore(
                url: IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID))),
            journal: try InvalidationJournal(store: SQLiteStore(
                url: IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID))),
            snapshotStore: snapshotStore,
            entityStore: try EntityStore(store: SQLiteStore(
                url: IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID))))
        try await engine.fullIndex()
        server = try IntelligenceMCPServer(
            workspaceRoot: ws.url, snapshotStore: snapshotStore)
    }

    // MARK: Protocol

    func testInitializeHandshake() {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
        ])
        let result = response?["result"] as? [String: Any]
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "beetcode-intelligence")
        XCTAssertEqual(result?["protocolVersion"] as? String,
                       IntelligenceMCPServer.protocolVersion)
    }

    func testToolsListIsSmallAndComplete() {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list",
        ])
        let result = response?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 12) // intentionally small (spec)
        let names = tools?.compactMap { $0["name"] as? String } ?? []
        for expected in ["workspace_overview", "workspace_context", "workspace_search",
                         "symbol_find", "symbol_callers", "symbol_callees",
                         "graph_neighbors", "graph_impact", "knowledge_search",
                         "knowledge_propose", "session_handoff", "claim_verify"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        // Every tool carries an input schema.
        XCTAssertTrue(tools?.allSatisfy { $0["inputSchema"] != nil } ?? false)
    }

    func testNotificationGetsNoResponse() {
        XCTAssertNil(server.handle([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ]))
    }

    func testUnknownMethodAndToolErrors() {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 3, "method": "bogus/method",
        ])
        let error = response?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)

        let badTool = server.handle([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "nope", "arguments": [:]],
        ])
        XCTAssertEqual((badTool?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: Tools

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) -> String {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])
        let result = response?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    func testWorkspaceOverview() {
        let text = call("workspace_overview")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("swift"), text)
    }

    func testSymbolFindCallersCallees() {
        XCTAssertTrue(call("symbol_find", ["name": "refreshToken"])
            .contains("Sources/Auth/AuthService.swift"))
        XCTAssertTrue(call("symbol_callers", ["name": "refreshToken"]).contains("resume"))
        XCTAssertTrue(call("symbol_callees", ["name": "refreshToken"]).contains("persistSession"))
        XCTAssertTrue(call("symbol_find", ["name": "nope"]).contains("no symbol"))
    }

    func testGraphNeighborsAndImpact() {
        let neighbors = call("graph_neighbors", ["name": "refreshToken"])
        XCTAssertTrue(neighbors.contains("calls"), neighbors)
        let impact = call("graph_impact", ["name": "refreshToken"])
        XCTAssertTrue(impact.contains("Direct callers:"), impact)
        XCTAssertTrue(impact.contains("resume"), impact)
    }

    func testWorkspaceSearch() {
        XCTAssertTrue(call("workspace_search", ["query": "session"])
            .contains("SessionManager"))
        XCTAssertTrue(call("workspace_search", ["query": "zzzzz"])
            .contains("no matches"))
    }

    func testWorkspaceContext() {
        let text = call("workspace_context", ["task": "how does refreshToken work"])
        XCTAssertTrue(text.contains("refreshToken"), text)
    }

    func testKnowledgeProposeAndSearch() {
        // Agent proposal without evidence → rejected by the pipeline.
        let rejected = call("knowledge_propose", [
            "kind": "pitfall", "scope": "Auth",
            "statement": "token refresh must debounce retries",
        ])
        XCTAssertTrue(rejected.contains("rejected"), rejected)

        // With real evidence → committed.
        let committed = call("knowledge_propose", [
            "kind": "pitfall", "scope": "Auth",
            "statement": "token refresh must debounce retries",
            "evidencePaths": ["Sources/Auth/AuthService.swift"],
        ])
        XCTAssertTrue(committed.contains("committed"), committed)

        let found = call("knowledge_search", ["query": "debounce"])
        XCTAssertTrue(found.contains("debounce"), found)
        let filtered = call("knowledge_search", ["query": "debounce", "kind": "decision"])
        XCTAssertTrue(filtered.contains("no knowledge"), filtered)
    }

    func testSessionHandoffWithoutStateIsHonest() {
        XCTAssertTrue(call("session_handoff").contains("no working state"))
    }

    func testClaimVerify() {
        XCTAssertTrue(call("claim_verify", ["type": "symbolExists", "a": "refreshToken"])
            .hasPrefix("VERIFIED"))
        XCTAssertTrue(call("claim_verify", ["type": "callExists", "a": "resume", "b": "persistSession"])
            .hasPrefix("FALSE"))
        XCTAssertTrue(call("claim_verify", ["type": "symbolExists", "a": "ghost"])
            .hasPrefix("FALSE"))
    }
}
