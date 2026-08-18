import Foundation

/// Adapts one MCP server tool to the AgentTool protocol. MCP tools always
/// run through the PermissionGate as `.execute` risk — a remote server can
/// never bypass the approval flow, regardless of what it claims.
struct MCPToolAdapter: AgentTool {

    let serverName: String
    let definition: MCPConnection.ToolDefinition
    let connection: MCPConnection

    /// Tool names must be globally unique in the executor registry; prefix
    /// with the server name (namespaced like OpenCode does).
    var name: String { "mcp__\(serverName)__\(definition.name)" }

    var summary: String {
        definition.description.isEmpty
            ? "MCP tool '\(definition.name)' via server '\(serverName)'"
            : definition.description
    }

    var risk: ToolRisk { .execute }

    var schemaText: String { definition.schemaJSON }

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("mcp:\(serverName)/\(definition.name) \(call.argumentsJSON)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        // Errors (MCPError or otherwise) propagate: the executor maps any
        // thrown error to a typed [error] observation the model can react to.
        try await connection.callTool(definition.name, argumentsJSON: call.argumentsJSON)
    }
}

/// Manages the lifecycle of all configured MCP servers for one agent
/// session: connect in parallel, collect tools, disconnect on teardown.
/// Failures are best-effort — a broken server never blocks the agent.
actor MCPRegistry {

    struct Result: Sendable {
        var tools: [any AgentTool] = []
        var connectedServers: [String] = []
        var errors: [String] = []
    }

    private var connections: [MCPConnection] = []

    /// Connects every configured server and returns their tools. Each server
    /// gets its own bounded connect attempt; timeouts are 30s total.
    func start(workspaceRoot: URL) async -> Result {
        let (servers, configErrors) = MCPConfig.load(workspaceRoot: workspaceRoot)
        var result = Result()
        result.errors = configErrors
        guard !servers.isEmpty else { return result }

        await withTaskGroup(of: (String, MCPConnection, [MCPConnection.ToolDefinition]?, String?).self) { group in
            for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
                group.addTask {
                    let connection = MCPConnection(name: name, config: config)
                    do {
                        let tools = try await connection.connect()
                        return (name, connection, tools, nil)
                    } catch {
                        return (name, connection, nil, error.localizedDescription)
                    }
                }
            }
            for await (name, connection, tools, failure) in group {
                if let tools {
                    connections.append(connection)
                    result.connectedServers.append(name)
                    for tool in tools {
                        result.tools.append(MCPToolAdapter(
                            serverName: name,
                            definition: tool,
                            connection: connection))
                    }
                } else {
                    result.errors.append("MCP server '\(name)': \(failure ?? "unknown failure")")
                    await connection.disconnect()
                }
            }
        }
        return result
    }

    /// Disconnects every live server (session teardown).
    func stop() async {
        for connection in connections {
            await connection.disconnect()
        }
        connections.removeAll()
    }
}
