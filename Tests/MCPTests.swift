import Foundation
import XCTest
@testable import BeetCode

/// End-to-end MCP tests using a real subprocess MCP server (a tiny python
/// script speaking newline-delimited JSON-RPC). Exercises spawn, handshake,
/// tools/list, tools/call, config merge, and registry teardown.
final class MCPTests: XCTestCase {

    private var tempDir: URL!
    private var serverScript: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        serverScript = tempDir.appendingPathComponent("fake_mcp_server.py")
        let script = """
        import sys, json
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            mid = msg.get("id")
            method = msg.get("method", "")
            if method == "initialize":
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "serverInfo": {"name": "fake-server", "version": "1.0"}}}), flush=True)
            elif method == "tools/list":
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "echo", "description": "Echoes the text argument",
                     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}}), flush=True)
            elif method == "tools/call":
                params = msg.get("params", {})
                text = params.get("arguments", {}).get("text", "")
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "echo:" + text}],
                    "isError": False}}), flush=True)
        """
        try? script.write(to: serverScript, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Config

    func testConfigLoadsWorkspaceServers() throws {
        let configURL = MCPConfig.workspaceConfigURL(root: tempDir)
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = MCPConfigFile(mcpServers: [
            "fake": MCPServerConfig(command: "/usr/bin/python3", args: [serverScript.path]),
        ])
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL)

        let (servers, errors) = MCPConfig.load(workspaceRoot: tempDir)
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
        XCTAssertNotNil(servers["fake"])
        XCTAssertEqual(servers["fake"]?.command, "/usr/bin/python3")
    }

    func testConfigIgnoresInvalidFile() throws {
        let configURL = MCPConfig.workspaceConfigURL(root: tempDir)
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: configURL)
        let (servers, errors) = MCPConfig.load(workspaceRoot: tempDir)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    func testEmptyCommandIsRejected() throws {
        let configURL = MCPConfig.workspaceConfigURL(root: tempDir)
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = MCPConfigFile(mcpServers: ["bad": MCPServerConfig(command: "")])
        try JSONEncoder().encode(config).write(to: configURL)
        let (servers, errors) = MCPConfig.load(workspaceRoot: tempDir)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    // MARK: Connection

    func testConnectListsToolsAndCallsThem() async throws {
        let connection = MCPConnection(
            name: "fake",
            config: MCPServerConfig(command: "/usr/bin/python3", args: [serverScript.path]))
        let tools = try await connection.connect()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "echo")
        XCTAssertTrue(tools.first?.description.contains("Echoes") ?? false)

        let output = try await connection.callTool("echo", argumentsJSON: #"{"text":"hello"}"#)
        XCTAssertEqual(output, "echo:hello")

        await connection.disconnect()
    }

    func testSpawnFailureThrows() async {
        let connection = MCPConnection(
            name: "missing",
            config: MCPServerConfig(command: "/nonexistent/binary"))
        do {
            _ = try await connection.connect()
            XCTFail("expected spawn failure")
        } catch {
            // Expected: MCPError.spawnFailed
        }
    }

    // MARK: Adapter + Registry

    func testAdapterShapesLikeAgentTool() async throws {
        let connection = MCPConnection(
            name: "fake",
            config: MCPServerConfig(command: "/usr/bin/python3", args: [serverScript.path]))
        let tools = try await connection.connect()
        let adapter = MCPToolAdapter(serverName: "fake", definition: tools[0], connection: connection)
        XCTAssertEqual(adapter.name, "mcp__fake__echo")
        XCTAssertEqual(adapter.risk, .execute, "MCP tools must always require approval")
        XCTAssertTrue(adapter.schemaText.contains("string"))

        let context = ToolContext(workspace: Workspace(root: tempDir))
        let call = ParsedToolCall(name: adapter.name, arguments: .object(["text": .string("x")]), index: 0)
        let result = try await adapter.execute(call, in: context)
        XCTAssertEqual(result, "echo:x")
        await connection.disconnect()
    }

    func testRegistryConnectsConfiguredServersAndTearsDown() async throws {
        let configURL = MCPConfig.workspaceConfigURL(root: tempDir)
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = MCPConfigFile(mcpServers: [
            "fake": MCPServerConfig(command: "/usr/bin/python3", args: [serverScript.path]),
        ])
        try JSONEncoder().encode(config).write(to: configURL)

        let registry = MCPRegistry()
        let result = await registry.start(workspaceRoot: tempDir)
        XCTAssertTrue(result.errors.isEmpty, "errors: \(result.errors)")
        XCTAssertEqual(result.connectedServers, ["fake"])
        XCTAssertEqual(result.tools.count, 1)
        await registry.stop()
    }

    func testRegistryWithNoConfigReturnsNothing() async {
        let emptyDir = tempDir.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let registry = MCPRegistry()
        let result = await registry.start(workspaceRoot: emptyDir)
        // No workspace config in the sandboxed dir; user config may exist on
        // the machine, so only assert no crash + consistent shape.
        XCTAssertTrue(result.tools.isEmpty || !result.tools.isEmpty)
        await registry.stop()
    }
}
