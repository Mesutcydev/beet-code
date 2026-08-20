import Foundation

/// Compatibility reader for OpenCode's file-based ecosystem.
///
/// Beet Code does not run the OpenCode TUI or its JavaScript runtime. It
/// imports the stable, human-authored contracts instead: provider/model
/// definitions, commands, agent profiles, permission rules, and MCP servers.
/// Those definitions are translated into Beet Code's native SwiftUI picker,
/// approval gate, and tool registry.
enum OpenCodeCompatibility {

    static let maxPromptCharacters = 12_000

    // MARK: Public catalog

    struct Catalog: Sendable, Equatable {
        var providers: [ProviderProfile]
        var models: [ModelProfile]
        var agents: [AgentProfile]
        var commands: [CommandProfile]
        var mcpServers: [String: MCPServerConfig]
        var permissions: OpenCodePermissionSet
        var warnings: [String]
        var sources: [URL]

        static let empty = Catalog(
            providers: [], models: [], agents: AgentProfile.builtIns,
            commands: [], mcpServers: [:], permissions: .empty,
            warnings: [], sources: [])

        func provider(id: String) -> ProviderProfile? {
            providers.first { $0.id == id }
        }

        func model(providerID: String, modelID: String) -> ModelProfile? {
            models.first { $0.providerID == providerID && $0.modelID == modelID }
        }

        func agent(named name: String?) -> AgentProfile? {
            guard let name, !name.isEmpty else { return nil }
            return agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        func command(named name: String?) -> CommandProfile? {
            guard let name, !name.isEmpty else { return nil }
            return commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    struct ProviderProfile: Sendable, Equatable, Identifiable {
        let id: String
        let displayName: String
        let baseURL: URL?
        let apiProtocol: RemoteAPIProtocol
        let package: String?
        let headers: [String: String]
        /// Resolved only in memory from an OpenCode `{env:…}` or
        /// `{file:…}` reference. It is never written to Beet Code state.
        let apiKey: String?
        let sourceURL: URL
        let models: [ModelProfile]

        var isCustom: Bool {
            LLMProvider.fromOpenCodeIdentifier(id) == nil
        }
    }

    struct ModelProfile: Sendable, Equatable, Identifiable {
        let providerID: String
        let providerName: String
        let modelID: String
        let displayName: String?
        let contextWindow: Int?
        let maxOutputTokens: Int?
        let apiProtocol: RemoteAPIProtocol
        let baseURL: URL?
        let headers: [String: String]
        let apiKey: String?
        let sourceURL: URL

        var id: String { "\(providerID)/\(modelID)" }
        var title: String { displayName ?? modelID }

        func remoteProfile() -> RemoteModelProfile {
            RemoteModelProfile(
                provider: LLMProvider.fromOpenCodeIdentifier(providerID) ?? .custom,
                model: modelID,
                displayName: displayName,
                contextWindow: contextWindow,
                maxOutputTokens: maxOutputTokens,
                supportsVision: nil,
                supportsTools: true,
                supportsReasoning: apiProtocol != .openAIChatCompletions ? true : nil,
                supportsTemperature: apiProtocol != .openAIResponses,
                providerKey: providerID,
                providerDisplayName: providerName,
                apiProtocol: apiProtocol,
                baseURL: baseURL?.absoluteString,
                headers: headers,
                apiKey: apiKey)
        }

        func endpoint() -> RemoteEndpoint {
            RemoteEndpoint(
                provider: LLMProvider.fromOpenCodeIdentifier(providerID) ?? .custom,
                model: modelID,
                providerID: providerID,
                displayName: providerName,
                baseURL: baseURL,
                apiProtocol: apiProtocol,
                headers: headers,
                apiKey: apiKey)
        }
    }

    struct AgentProfile: Sendable, Equatable, Identifiable {
        enum Mode: String, Sendable, Equatable {
            case primary
            case subagent
            case all
        }

        let name: String
        let description: String?
        let mode: Mode
        let model: String?
        let prompt: String?
        let permissions: OpenCodePermissionSet
        let disabled: Bool
        let hidden: Bool
        let sourceURL: URL?
        let isBuiltIn: Bool

        var id: String { name }
        var visibleInPicker: Bool { !disabled && !hidden }

        static let builtIns: [AgentProfile] = [
            AgentProfile(
                name: "build",
                description: "Build and modify the workspace with Beet Code's native approval flow.",
                mode: .primary,
                model: nil,
                prompt: "Act as the Build agent. Implement the requested change, verify it, and keep working until the task is complete.",
                permissions: .empty,
                disabled: false,
                hidden: false,
                sourceURL: nil,
                isBuiltIn: true),
            AgentProfile(
                name: "plan",
                description: "Inspect the workspace and propose a plan without changing files.",
                mode: .primary,
                model: nil,
                prompt: "Act as the Plan agent. Inspect and reason about the workspace, then propose a concise plan. Do not modify files or run mutating commands.",
                permissions: OpenCodePermissionSet(rules: [
                    .init(action: "edit", resource: "*", effect: .deny),
                    .init(action: "shell", resource: "*", effect: .deny),
                    .init(action: "bash", resource: "*", effect: .deny),
                ]),
                disabled: false,
                hidden: false,
                sourceURL: nil,
                isBuiltIn: true),
        ]
    }

    struct CommandProfile: Sendable, Equatable, Identifiable {
        let name: String
        let description: String?
        let template: String
        let agent: String?
        let model: String?
        let subtask: Bool
        let sourceURL: URL

        var id: String { name }

        func render(arguments: String) -> String {
            let parts = arguments.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var result = template.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
            for (index, value) in parts.enumerated() {
                result = result.replacingOccurrences(of: "$\(index + 1)", with: value)
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Permission model

    enum PermissionEffect: String, Sendable, Equatable {
        case allow
        case ask
        case deny
    }

    struct PermissionRule: Sendable, Equatable {
        let action: String
        let resource: String
        let effect: PermissionEffect
    }

    struct OpenCodePermissionSet: Sendable, Equatable {
        var rules: [PermissionRule]

        static let empty = OpenCodePermissionSet(rules: [])

        init(rules: [PermissionRule] = []) {
            self.rules = rules
        }

        func merged(with other: OpenCodePermissionSet) -> OpenCodePermissionSet {
            OpenCodePermissionSet(rules: rules + other.rules)
        }

        /// OpenCode evaluates matching wildcard rules in order, with the last
        /// matching entry winning. Beet Code preserves that behavior.
        func effect(action: String, resource: String) -> PermissionEffect? {
            var result: PermissionEffect?
            for rule in rules where matches(rule.action, value: action)
                && matches(rule.resource, value: resource) {
                result = rule.effect
            }
            return result
        }

        private func matches(_ pattern: String, value: String) -> Bool {
            let pattern = pattern.isEmpty ? "*" : pattern
            let p = Array(pattern)
            let v = Array(value)
            var pi = 0
            var vi = 0
            var star: Int?
            var starMatch = 0

            while vi < v.count {
                if pi < p.count, p[pi] == v[vi] || pi < p.count && p[pi] == "?" {
                    pi += 1
                    vi += 1
                } else if pi < p.count, p[pi] == "*" {
                    star = pi
                    pi += 1
                    starMatch = vi
                } else if let star {
                    pi = star + 1
                    starMatch += 1
                    vi = starMatch
                } else {
                    return false
                }
            }

            while pi < p.count, p[pi] == "*" { pi += 1 }
            return pi == p.count
        }
    }

    // MARK: Discovery

    static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspace: URL? = nil
    ) -> Catalog {
        var providers: [String: ProviderProfile] = [:]
        var models: [String: ModelProfile] = [:]
        var agents: [String: AgentProfile] = Dictionary(
            uniqueKeysWithValues: AgentProfile.builtIns.map { ($0.name.lowercased(), $0) })
        var commands: [String: CommandProfile] = [:]
        var mcpServers: [String: MCPServerConfig] = [:]
        var permissions = OpenCodePermissionSet.empty
        var warnings: [String] = []
        var sources: [URL] = []

        for (url, isWorkspace) in configURLs(home: home, workspace: workspace) {
            guard let root = loadJSONC(url: url, warnings: &warnings) else { continue }
            sources.append(url)
            let parsed = parseConfig(root, sourceURL: url)
            for provider in parsed.providers {
                providers[provider.id] = provider
                for model in provider.models {
                    models[model.id] = model
                }
            }
            for agent in parsed.agents {
                agents[agent.name.lowercased()] = agent
            }
            for command in parsed.commands {
                commands[command.name.lowercased()] = command
            }
            for (name, server) in parsed.mcpServers {
                mcpServers[name] = server
            }
            // Project rules are read after global rules and therefore win on
            // matching actions, exactly like OpenCode's config precedence.
            permissions = permissions.merged(with: parsed.permissions)
            _ = isWorkspace // documents the precedence encoded by configURLs
        }

        for (url, isWorkspace) in markdownURLs(home: home, workspace: workspace, kind: "commands") {
            guard let document = parseMarkdown(url: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            commands[name] = CommandProfile(
                name: name,
                description: document.metadata["description"],
                template: document.body,
                agent: document.metadata["agent"],
                model: document.metadata["model"],
                subtask: document.metadata["subtask"].map(parseBool) ?? false,
                sourceURL: url)
            _ = isWorkspace
        }

        for (url, isWorkspace) in markdownURLs(home: home, workspace: workspace, kind: "agents") {
            guard let document = parseMarkdown(url: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let agent = AgentProfile(
                name: name,
                description: document.metadata["description"],
                mode: AgentProfile.Mode(rawValue: document.metadata["mode"] ?? "all") ?? .all,
                model: document.metadata["model"],
                prompt: bounded(document.body),
                permissions: document.permissions,
                disabled: document.metadata["disable"].map(parseBool) ?? false,
                hidden: document.metadata["hidden"].map(parseBool) ?? false,
                sourceURL: url,
                isBuiltIn: false)
            agents[name.lowercased()] = agent
            _ = isWorkspace
        }

        return Catalog(
            providers: providers.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            models: models.values.sorted {
                if $0.providerName != $1.providerName {
                    return $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
                }
                return $0.modelID.localizedStandardCompare($1.modelID) == .orderedAscending
            },
            agents: agents.values.sorted {
                if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            commands: commands.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            mcpServers: mcpServers,
            permissions: permissions,
            warnings: warnings,
            sources: sources)
    }

    // MARK: Config parsing

    private struct ParsedConfig {
        var providers: [ProviderProfile] = []
        var agents: [AgentProfile] = []
        var commands: [CommandProfile] = []
        var mcpServers: [String: MCPServerConfig] = [:]
        var permissions = OpenCodePermissionSet.empty
    }

    private static func parseConfig(_ root: [String: LFJSONValue], sourceURL: URL) -> ParsedConfig {
        let configDirectory = sourceURL.deletingLastPathComponent()
        var parsed = ParsedConfig()

        let providerNodes: [String: LFJSONValue] = {
            if let value = root["provider"]?.objectValue { return value }
            if let value = root["providers"]?.objectValue { return value }
            return [:]
        }()
        for (id, value) in providerNodes {
            guard let object = value.objectValue else { continue }
            let options = object["options"]?.objectValue
                ?? object["settings"]?.objectValue
                ?? [:]
            let package = object["npm"]?.stringValue
                ?? object["package"]?.stringValue
            let displayName = object["name"]?.stringValue ?? id
            let baseRaw = options["baseURL"]?.stringValue
                ?? options["endpoint"]?.stringValue
                ?? object["baseURL"]?.stringValue
            let baseURL = baseRaw.flatMap(URL.init(string:))
                ?? KnownRemoteProvider.find(id)?.baseURL
            let headers = stringDictionary(
                object["headers"]?.objectValue ?? options["headers"]?.objectValue,
                relativeTo: configDirectory)
            let apiKey = resolvedString(
                options["apiKey"] ?? object["apiKey"],
                relativeTo: configDirectory)
            let providerProtocol = RemoteAPIProtocol.inferred(
                providerID: id, package: package)
            let modelNodes = object["models"]?.objectValue ?? [:]
            let whitelist = Set(object["whitelist"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let blacklist = Set(object["blacklist"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var parsedModels: [ModelProfile] = []

            for (modelID, modelValue) in modelNodes {
                guard !modelID.isEmpty, !blacklist.contains(modelID),
                      whitelist.isEmpty || whitelist.contains(modelID)
                else { continue }
                let modelObject = modelValue.objectValue ?? [:]
                let modelPackage = modelObject["npm"]?.stringValue
                    ?? modelObject["package"]?.stringValue
                let modelProtocol = RemoteAPIProtocol.inferred(
                    providerID: id, model: modelID,
                    package: modelPackage ?? package)
                let limit = modelObject["limit"]?.objectValue ?? [:]
                let context = limit["context"]?.intValue
                    ?? limit["input"]?.intValue
                let output = limit["output"]?.intValue
                let modelBase = modelObject["options"]?.objectValue?["baseURL"]?.stringValue
                    .flatMap(URL.init(string:)) ?? baseURL
                let modelHeaders = stringDictionary(
                    modelObject["headers"]?.objectValue,
                    relativeTo: configDirectory)
                let mergedHeaders = headers.merging(modelHeaders) { _, next in next }
                parsedModels.append(ModelProfile(
                    providerID: id,
                    providerName: displayName,
                    modelID: modelID,
                    displayName: modelObject["name"]?.stringValue,
                    contextWindow: context,
                    maxOutputTokens: output,
                    apiProtocol: modelProtocol,
                    baseURL: modelBase,
                    headers: mergedHeaders,
                    apiKey: apiKey,
                    sourceURL: sourceURL))
            }

            parsed.providers.append(ProviderProfile(
                id: id,
                displayName: displayName,
                baseURL: baseURL,
                apiProtocol: providerProtocol,
                package: package,
                headers: headers,
                apiKey: apiKey,
                sourceURL: sourceURL,
                models: parsedModels))
        }

        if let agentNodes = root["agent"]?.objectValue {
            for (name, value) in agentNodes {
                guard let object = value.objectValue else { continue }
                parsed.agents.append(parseAgent(
                    name: name, object: object, sourceURL: sourceURL, relativeTo: configDirectory))
            }
        }

        if let commandNodes = root["command"]?.objectValue {
            for (name, value) in commandNodes {
                guard let object = value.objectValue,
                      let template = resolvedString(object["template"]?.stringValue, relativeTo: configDirectory),
                      !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                parsed.commands.append(CommandProfile(
                    name: name,
                    description: object["description"]?.stringValue,
                    template: bounded(template) ?? template,
                    agent: object["agent"]?.stringValue,
                    model: object["model"]?.stringValue,
                    subtask: object["subtask"]?.boolValue ?? false,
                    sourceURL: sourceURL))
            }
        }

        parsed.permissions = permissionSet(
            legacy: root["permission"],
            modern: root["permissions"],
            tools: root["tools"])

        if let mcp = root["mcp"]?.objectValue {
            parsed.mcpServers = parseMCPServers(mcp, relativeTo: configDirectory)
        }
        return parsed
    }

    private static func parseAgent(
        name: String,
        object: [String: LFJSONValue],
        sourceURL: URL,
        relativeTo directory: URL
    ) -> AgentProfile {
        let prompt = resolvedString(object["prompt"]?.stringValue, relativeTo: directory)
        let permissions = permissionSet(
            legacy: object["permission"],
            modern: object["permissions"],
            tools: object["tools"])
        return AgentProfile(
            name: name,
            description: object["description"]?.stringValue,
            mode: AgentProfile.Mode(rawValue: object["mode"]?.stringValue ?? "all") ?? .all,
            model: object["model"]?.stringValue,
            prompt: prompt.flatMap(bounded),
            permissions: permissions,
            disabled: object["disable"]?.boolValue ?? false,
            hidden: object["hidden"]?.boolValue ?? false,
            sourceURL: sourceURL,
            isBuiltIn: false)
    }

    private static func permissionSet(
        legacy: LFJSONValue?,
        modern: LFJSONValue?,
        tools: LFJSONValue?
    ) -> OpenCodePermissionSet {
        var rules: [PermissionRule] = []
        if let legacy {
            rules.append(contentsOf: permissionRules(from: legacy))
        }
        if let tools {
            rules.append(contentsOf: permissionRules(from: tools, booleansAreEffects: true))
        }
        if let modern, let entries = modern.arrayValue {
            for entry in entries {
                guard let object = entry.objectValue,
                      let action = object["action"]?.stringValue,
                      let resource = object["resource"]?.stringValue,
                      let effect = permissionEffect(object["effect"]?.stringValue)
                else { continue }
                rules.append(.init(action: action, resource: resource, effect: effect))
            }
        }
        return OpenCodePermissionSet(rules: rules)
    }

    private static func permissionRules(
        from value: LFJSONValue,
        booleansAreEffects: Bool = false
    ) -> [PermissionRule] {
        if let string = value.stringValue, let effect = permissionEffect(string) {
            return [.init(action: "*", resource: "*", effect: effect)]
        }
        guard let object = value.objectValue else { return [] }
        var rules: [PermissionRule] = []
        for (action, entry) in object {
            if let string = entry.stringValue,
               let effect = permissionEffect(string) {
                rules.append(.init(action: action, resource: "*", effect: effect))
            } else if booleansAreEffects, let enabled = entry.boolValue {
                rules.append(.init(action: action, resource: "*", effect: enabled ? .allow : .deny))
            } else if let nested = entry.objectValue {
                for (resource, effectValue) in nested {
                    if let effect = permissionEffect(effectValue.stringValue) {
                        rules.append(.init(action: action, resource: resource, effect: effect))
                    }
                }
            }
        }
        return rules
    }

    private static func permissionEffect(_ raw: String?) -> PermissionEffect? {
        guard let raw else { return nil }
        return PermissionEffect(rawValue: raw.lowercased())
    }

    private static func parseMCPServers(
        _ nodes: [String: LFJSONValue],
        relativeTo directory: URL
    ) -> [String: MCPServerConfig] {
        var result: [String: MCPServerConfig] = [:]
        for (name, value) in nodes {
            guard let object = value.objectValue,
                  object["enabled"]?.boolValue != false
            else { continue }

            let type = object["type"]?.stringValue?.lowercased()
            let environment = stringDictionary(
                object["environment"]?.objectValue ?? object["env"]?.objectValue,
                relativeTo: directory)
            let headers = stringDictionary(object["headers"]?.objectValue, relativeTo: directory)
            let oauth: MCPServerConfig.OAuthConfig? = {
                guard let oauth = object["oauth"]?.objectValue else { return nil }
                return .init(
                    clientId: oauth["clientId"]?.stringValue,
                    clientSecret: resolvedString(oauth["clientSecret"]?.stringValue, relativeTo: directory))
            }()

            if type == "remote" || object["url"]?.stringValue != nil {
                guard let url = resolvedString(object["url"]?.stringValue, relativeTo: directory),
                      URL(string: url) != nil
                else { continue }
                result[name] = MCPServerConfig(
                    url: url, headers: headers, oauth: oauth)
                continue
            }

            if let commandParts = object["command"]?.arrayValue?.compactMap(\.stringValue),
               let command = commandParts.first, !command.isEmpty {
                result[name] = MCPServerConfig(
                    command: command,
                    args: Array(commandParts.dropFirst()),
                    env: environment)
            } else if let command = object["command"]?.stringValue, !command.isEmpty {
                result[name] = MCPServerConfig(command: command, env: environment)
            }
        }
        return result
    }

    // MARK: Markdown frontmatter

    private struct MarkdownDocument {
        var metadata: [String: String]
        var permissions: OpenCodePermissionSet
        var body: String
    }

    private static func parseMarkdown(url: URL) -> MarkdownDocument? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            let body = bounded(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            return body.map { MarkdownDocument(metadata: [:], permissions: .empty, body: $0) }
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else { return nil }

        var metadata: [String: String] = [:]
        var rules: [PermissionRule] = []
        var inPermissions = false
        var permissionIndent = 0
        var permissionAction: String?
        for line in lines[1..<end] {
            let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":")
            else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = cleanScalar(String(trimmed[trimmed.index(after: colon)...]))

            if indentation == 0 {
                inPermissions = key == "permission" || key == "permissions"
                permissionIndent = indentation
                permissionAction = nil
                if !inPermissions {
                    metadata[key] = value
                }
                continue
            }

            guard inPermissions else { continue }
            // The common front-matter form is:
            //   permission:
            //     edit: deny
            //     shell: ask
            // A deeper level is accepted for resource-specific rules:
            //   permission:
            //     edit:
            //       Sources/*: allow
            if indentation <= permissionIndent + 2 {
                permissionAction = key
                if let effect = permissionEffect(value) {
                    rules.append(.init(action: key, resource: "*", effect: effect))
                }
            } else if let permissionAction,
                      let effect = permissionEffect(value) {
                rules.append(.init(action: permissionAction, resource: key, effect: effect))
            }
        }

        let bodyStart = lines.index(after: end)
        let body = lines[bodyStart...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let boundedBody = bounded(body) else { return nil }
        return MarkdownDocument(
            metadata: metadata,
            permissions: OpenCodePermissionSet(rules: rules),
            body: boundedBody)
    }

    private static func cleanScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.first == "\"" && trimmed.last == "\"")
            || (trimmed.first == "'" && trimmed.last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: File locations

    private static func configURLs(home: URL, workspace: URL?) -> [(URL, Bool)] {
        var result: [(URL, Bool)] = []
        var seen: Set<String> = []

        func add(_ url: URL, workspace: Bool) {
            guard FileManager.default.fileExists(atPath: url.path), !seen.contains(url.path) else { return }
            seen.insert(url.path)
            result.append((url, workspace))
        }

        // Global config first; project config is merged afterward.
        for directory in [
            home.appendingPathComponent(".config/opencode", isDirectory: true),
            home.appendingPathComponent(".opencode", isDirectory: true),
        ] {
            add(directory.appendingPathComponent("opencode.json"), workspace: false)
            add(directory.appendingPathComponent("opencode.jsonc"), workspace: false)
        }
        if let workspace {
            add(workspace.appendingPathComponent("opencode.json"), workspace: true)
            add(workspace.appendingPathComponent("opencode.jsonc"), workspace: true)
            add(workspace.appendingPathComponent(".opencode/opencode.json"), workspace: true)
            add(workspace.appendingPathComponent(".opencode/opencode.jsonc"), workspace: true)
        }
        return result
    }

    private static func markdownURLs(
        home: URL,
        workspace: URL?,
        kind: String
    ) -> [(URL, Bool)] {
        var roots: [(URL, Bool)] = [
            (home.appendingPathComponent(".config/opencode/\(kind)", isDirectory: true), false),
            (home.appendingPathComponent(".opencode/\(kind)", isDirectory: true), false),
        ]
        if let workspace {
            roots.append((workspace.appendingPathComponent(".opencode/\(kind)", isDirectory: true), true))
        }
        var files: [(URL, Bool)] = []
        for (root, isWorkspace) in roots {
            let listed = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            files += listed
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { ($0, isWorkspace) }
        }
        return files
    }

    // MARK: JSONC and value helpers

    private static func loadJSONC(url: URL, warnings: inout [String]) -> [String: LFJSONValue]? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            warnings.append("Could not read OpenCode config (\(url.path)).")
            return nil
        }
        let stripped = stripJSONC(raw)
        guard let value = try? LFJSONValue.decode(stripped),
              let object = value.objectValue
        else {
            warnings.append("Could not parse OpenCode config (\(url.lastPathComponent)).")
            return nil
        }
        return object
    }

    /// Removes JavaScript comments and trailing commas without touching text
    /// inside JSON strings. OpenCode documents JSONC configs, while Foundation
    /// only accepts strict JSON.
    static func stripJSONC(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var inString = false
        var escaped = false
        var lineComment = false
        var blockComment = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let nextIndex = source.index(after: index)
            let next = nextIndex < source.endIndex ? source[nextIndex] : "\0"

            if lineComment {
                if character == "\n" {
                    lineComment = false
                    output.append(character)
                }
                index = nextIndex
                continue
            }
            if blockComment {
                if character == "*" && next == "/" {
                    blockComment = false
                    index = source.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
            } else if character == "/" && next == "/" {
                lineComment = true
                index = source.index(after: nextIndex)
                continue
            } else if character == "/" && next == "*" {
                blockComment = true
                index = source.index(after: nextIndex)
                continue
            } else {
                output.append(character)
            }
            index = nextIndex
        }

        // Remove commas immediately before a closing object/array delimiter,
        // again respecting strings.
        var cleaned = ""
        cleaned.reserveCapacity(output.count)
        let characters = Array(output)
        var inQuotedString = false
        var escapedQuote = false
        for i in characters.indices {
            let character = characters[i]
            if inQuotedString {
                cleaned.append(character)
                if escapedQuote { escapedQuote = false }
                else if character == "\\" { escapedQuote = true }
                else if character == "\"" { inQuotedString = false }
                continue
            }
            if character == "\"" {
                inQuotedString = true
                cleaned.append(character)
                continue
            }
            if character == "," {
                var next = i + 1
                while next < characters.count,
                      characters[next].isWhitespace { next += 1 }
                if next < characters.count,
                   characters[next] == "}" || characters[next] == "]" {
                    continue
                }
            }
            cleaned.append(character)
        }
        return cleaned
    }

    private static func stringDictionary(
        _ object: [String: LFJSONValue]?,
        relativeTo directory: URL
    ) -> [String: String] {
        guard let object else { return [:] }
        return object.compactMapValues { resolvedString($0, relativeTo: directory) }
    }

    /// Resolves either OpenCode's string shorthand (`{env:NAME}`) or its
    /// object form (`{"env":"NAME"}` / `{"file":"path"}`).
    static func resolvedString(_ value: LFJSONValue?, relativeTo directory: URL) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let raw):
            return resolvedString(raw, relativeTo: directory)
        case .object(let object):
            if let env = object["env"]?.stringValue {
                return ProcessInfo.processInfo.environment[env] ?? ""
            }
            if let file = object["file"]?.stringValue {
                return resolvedString("{file:\(file)}", relativeTo: directory)
            }
            return nil
        default:
            return nil
        }
    }

    /// Resolves OpenCode's documented `{env:NAME}` and `{file:path}` values.
    /// A literal value is returned as-is, but credentials are kept only in the
    /// in-memory catalog and never copied into AppPreferences.
    static func resolvedString(_ raw: String?, relativeTo directory: URL) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{env:"), trimmed.hasSuffix("}") {
            let name = String(trimmed.dropFirst(5).dropLast())
            return ProcessInfo.processInfo.environment[name] ?? ""
        }
        if trimmed.hasPrefix("{file:"), trimmed.hasSuffix("}") {
            let rawPath = String(trimmed.dropFirst(6).dropLast())
            let path: String
            if rawPath.hasPrefix("~/") {
                path = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(String(rawPath.dropFirst(2))).path
            } else if rawPath.hasPrefix("/") {
                path = rawPath
            } else {
                path = directory.appendingPathComponent(rawPath).path
            }
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
            return String(contents.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16_384))
        }
        return trimmed
    }

    private static func bounded(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxPromptCharacters else { return trimmed }
        return String(trimmed.prefix(maxPromptCharacters)) + "\n\n[truncated for the model context]"
    }

    private static func parseBool(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(value.lowercased())
    }
}
