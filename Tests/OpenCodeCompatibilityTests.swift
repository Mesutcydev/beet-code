import Foundation
import XCTest
@testable import BeetCode

final class OpenCodeCompatibilityTests: XCTestCase {

    func testJSONCConfigImportsProvidersModelsCommandsAgentsMCPAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-opencode-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = """
        {
          // OpenCode JSONC permits comments and trailing commas.
          "provider": {
            "acme": {
              "name": "Acme Gateway",
              "npm": "@ai-sdk/openai-compatible",
              "options": {
                "baseURL": "https://example.invalid/v1",
                "apiKey": "{env:BEETCODE_TEST_MISSING_KEY}",
              },
              "models": {
                "acme-reasoner": {
                  "name": "Acme Reasoner",
                  "limit": { "context": 64000, "output": 8192 },
                },
              },
            },
          },
          "agent": {
            "reviewer": {
              "description": "Review without editing",
              "mode": "primary",
              "prompt": "Review the requested change carefully.",
              "permission": { "edit": "deny", "shell": "ask" },
            },
          },
          "command": {
            "review": {
              "description": "Review a target",
              "template": "Review $ARGUMENTS and report findings.",
              "agent": "reviewer",
            },
          },
          "mcp": {
            "local-tools": {
              "type": "local",
              "command": ["bun", "x", "mcp-server"],
              "environment": { "MODE": "test" },
            },
            "remote-tools": {
              "type": "remote",
              "url": "https://example.invalid/mcp",
              "headers": { "X-Test": "1" },
            },
          },
          "permissions": [
            { "action": "edit", "resource": "*", "effect": "deny" },
            { "action": "edit", "resource": "Sources/*", "effect": "allow" },
          ],
        }
        """
        try config.write(
            to: configDirectory.appendingPathComponent("opencode.jsonc"),
            atomically: true,
            encoding: .utf8)

        let markdownDirectory = workspace.appendingPathComponent(".opencode/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: markdownDirectory, withIntermediateDirectories: true)
        try """
        ---
        description: Inspect a file
        agent: reviewer
        ---
        Inspect $1 and explain the risk.
        """.write(
            to: markdownDirectory.appendingPathComponent("inspect.md"),
            atomically: true,
            encoding: .utf8)

        let catalog = OpenCodeCompatibility.load(home: root, workspace: workspace)
        XCTAssertEqual(catalog.provider(id: "acme")?.displayName, "Acme Gateway")
        let model = try XCTUnwrap(catalog.model(providerID: "acme", modelID: "acme-reasoner"))
        XCTAssertEqual(model.contextWindow, 64000)
        XCTAssertEqual(model.apiProtocol, .openAIChatCompletions)
        XCTAssertEqual(catalog.command(named: "review")?.render(arguments: "Sources/App.swift"),
                       "Review Sources/App.swift and report findings.")
        XCTAssertNotNil(catalog.command(named: "inspect"))
        XCTAssertEqual(catalog.agent(named: "reviewer")?.mode, .primary)
        XCTAssertEqual(catalog.mcpServers["local-tools"]?.command, "bun")
        XCTAssertEqual(catalog.mcpServers["local-tools"]?.args, ["x", "mcp-server"])
        XCTAssertEqual(catalog.mcpServers["remote-tools"]?.url, "https://example.invalid/mcp")
        XCTAssertEqual(catalog.permissions.effect(action: "edit", resource: "Sources/App.swift"), .allow)
        XCTAssertEqual(catalog.permissions.effect(action: "edit", resource: "Tests/AppTests.swift"), .deny)
    }

    func testOpenCodeWildcardRulesUseLastMatchingRule() {
        let permissions = OpenCodeCompatibility.OpenCodePermissionSet(rules: [
            .init(action: "edit", resource: "*", effect: .deny),
            .init(action: "edit", resource: "Sources/*", effect: .allow),
            .init(action: "edit", resource: "Sources/Generated/*", effect: .deny),
        ])
        XCTAssertEqual(permissions.effect(action: "edit", resource: "Sources/App.swift"), .allow)
        XCTAssertEqual(permissions.effect(action: "edit", resource: "Sources/Generated/Schema.swift"), .deny)
        XCTAssertNil(permissions.effect(action: "read", resource: "Sources/App.swift"))
    }

    func testMarkdownAgentPermissionsKeepSeparateActions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-opencode-agent-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".opencode/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        description: Review only
        permission:
          edit: deny
          shell: ask
        ---
        Review the workspace without making changes.
        """.write(
            to: agents.appendingPathComponent("reviewer.md"),
            atomically: true,
            encoding: .utf8)

        let catalog = OpenCodeCompatibility.load(home: root)
        let agent = try XCTUnwrap(catalog.agent(named: "reviewer"))
        XCTAssertEqual(agent.permissions.effect(action: "edit", resource: "Sources/App.swift"), .deny)
        XCTAssertEqual(agent.permissions.effect(action: "shell", resource: "git status"), .ask)
    }

    func testRemoteProtocolInferenceCoversMajorProviderPackages() {
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "anthropic"), .anthropicMessages)
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "google", package: "@ai-sdk/google"), .gemini)
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "custom", package: "@ai-sdk/openai-compatible"), .openAIChatCompletions)
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "custom", package: "@ai-sdk/openai"), .openAIResponses)
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "opencode", model: "gpt-5.6-luna"), .openAIResponses)
        XCTAssertEqual(RemoteAPIProtocol.inferred(providerID: "opencode", model: "claude-sonnet"), .anthropicMessages)
    }

    func testKnownGatewayPresetsProduceDynamicEndpoints() throws {
        XCTAssertGreaterThanOrEqual(KnownRemoteProvider.all.count, 10)
        let groq = try XCTUnwrap(KnownRemoteProvider.find("groq"))
        let endpoint = groq.endpoint(model: "llama-3.3-70b-versatile")
        XCTAssertEqual(endpoint.provider, .custom)
        XCTAssertEqual(endpoint.providerID, "groq")
        XCTAssertEqual(endpoint.effectiveProtocol, .openAIChatCompletions)
        XCTAssertEqual(endpoint.effectiveBaseURL?.host, "api.groq.com")
    }

    func testRuntimeCredentialsAreExcludedFromPersistedEndpointMetadata() throws {
        let profile = RemoteModelProfile(
            provider: .custom,
            model: "local-model",
            providerKey: "private-gateway",
            providerDisplayName: "Private Gateway",
            apiProtocol: .openAIChatCompletions,
            baseURL: "http://127.0.0.1:1234/v1",
            apiKey: "runtime-only-test-secret")
        let endpoint = profile.endpoint()
        let profileJSON = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        let endpointJSON = String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self)
        XCTAssertFalse(profileJSON.contains("runtime-only-test-secret"))
        XCTAssertFalse(endpointJSON.contains("runtime-only-test-secret"))
    }

    func testResponsesSSEEventsBecomeTranscriptDeltasAndToolProtocol() throws {
        let text = RemoteLLMClient.processSSELine(
            Array("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}".utf8))
        XCTAssertEqual(text, .text("hello"))

        let tool = RemoteLLMClient.processSSELine(
            Array("data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}".utf8))
        XCTAssertEqual(tool, .toolFragment(index: 0, name: nil, arguments: "{\"path\":\"README.md\"}"))

        let usage = RemoteLLMClient.processSSELine(
            Array("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":4}}}".utf8))
        XCTAssertEqual(usage, .usage(.init(promptTokens: 12, completionTokens: 4)))
    }
}
