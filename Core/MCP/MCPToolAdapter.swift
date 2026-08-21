import Foundation

/// Shared tool shape across MCP transports (stdio + HTTP/SSE).
struct MCPToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var schemaJSON: String
}

/// What every MCP transport must offer the registry: connect, call, drop.
/// Both `MCPConnection` (stdio) and `MCPHTTPConnection` (Streamable-HTTP)
/// conform.
protocol MCPTransport: Actor, Sendable {
    func callTool(_ toolName: String, argumentsJSON: String, timeout: TimeInterval) async throws -> String
    func disconnect() async
}

/// Adapts one MCP server tool to the AgentTool protocol. MCP tools always
/// run through the PermissionGate as `.execute` risk — a remote server can
/// never bypass the approval flow, regardless of what it claims.
struct MCPToolAdapter: AgentTool {

    let serverName: String
    let definition: MCPToolDefinition
    let transport: any MCPTransport

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
        try await transport.callTool(definition.name, argumentsJSON: call.argumentsJSON, timeout: 60)
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

    private var transports: [any MCPTransport] = []

    /// Connects every configured server and returns their tools. Each server
    /// gets its own bounded connect attempt; timeouts are bounded internally.
    /// stdio entries spawn a child process; `url` entries speak
    /// Streamable-HTTP (JSON body or SSE response carriage) with optional
    /// OAuth 2.0 (PKCE + refresh) when the entry carries an `oauth` block.
    func start(
        workspaceRoot: URL,
        includeOpenCode: Bool = true,
        includeWorkspace: Bool = false
    ) async -> Result {
        let (servers, configErrors) = MCPConfig.load(
            workspaceRoot: workspaceRoot,
            includeOpenCode: includeOpenCode,
            includeWorkspace: includeWorkspace)
        var result = Result()
        result.errors = configErrors
        guard !servers.isEmpty else { return result }

        await withTaskGroup(of: (String, (any MCPTransport)?, [MCPToolDefinition]?, String?).self) { group in
            for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
                group.addTask {
                    switch config.transport {
                    case .stdio:
                        let connection = MCPConnection(name: name, config: config)
                        do {
                            let tools = try await connection.connect()
                            let shared = tools.map {
                                MCPToolDefinition(
                                    name: $0.name, description: $0.description, schemaJSON: $0.schemaJSON)
                            }
                            return (name, connection, shared, nil)
                        } catch {
                            return (name, nil, nil, error.localizedDescription)
                        }
                    case .http:
                        guard let urlString = config.url, let url = URL(string: urlString) else {
                            return (name, nil, nil, "invalid url")
                        }
                        // OAuth is opt-in per server entry (an `oauth` block,
                        // possibly empty) so plain servers never trigger an
                        // unexpected browser login.
                        let auth: MCPOAuthProvider? = config.oauth != nil
                            ? MCPOAuthProvider(
                                serverName: name,
                                clientID: config.oauth?.clientId,
                                clientSecret: config.oauth?.clientSecret)
                            : nil
                        let connection = MCPHTTPConnection(
                            name: name, url: url, headers: config.headers, auth: auth)
                        do {
                            let tools = try await connection.connect()
                            let shared = tools.map {
                                MCPToolDefinition(
                                    name: $0.name, description: $0.description, schemaJSON: $0.schemaJSON)
                            }
                            return (name, connection, shared, nil)
                        } catch {
                            await connection.disconnect()
                            return (name, nil, nil, error.localizedDescription)
                        }
                    }
                }
            }
            for await (name, transport, tools, failure) in group {
                if let tools, let transport {
                    transports.append(transport)
                    result.connectedServers.append(name)
                    for tool in tools {
                        result.tools.append(MCPToolAdapter(
                            serverName: name,
                            definition: tool,
                            transport: transport))
                    }
                } else {
                    result.errors.append("MCP server '\(name)': \(failure ?? "unknown failure")")
                }
            }
        }
        return result
    }

    /// Disconnects every live server (session teardown).
    func stop() async {
        for transport in transports {
            await transport.disconnect()
        }
        transports.removeAll()
    }
}
