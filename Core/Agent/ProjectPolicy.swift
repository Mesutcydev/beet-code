import Foundation

/// Optional, non-secret project policy. It is intentionally separate from
/// provider credentials: a repository can share this file without exposing an
/// API key. The policy is compatible with the parts of OpenCode's permission
/// vocabulary that Beet Code can enforce natively.
struct ProjectPolicy: Codable, Sendable, Equatable {
    enum OutputStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case concise
        case normal
        case detailed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .concise: "Concise"
            case .normal: "Normal"
            case .detailed: "Detailed"
            }
        }

        var help: String {
            switch self {
            case .concise: "Short answers focused on the result and next action."
            case .normal: "Balanced explanations with the useful verification details."
            case .detailed: "More context, rationale, and implementation details in the final answer."
            }
        }
    }

    struct Permission: Codable, Sendable, Equatable {
        let action: String
        let resource: String
        let effect: String

        var openCodeRule: OpenCodeCompatibility.PermissionRule? {
            guard let value = OpenCodeCompatibility.PermissionEffect(rawValue: effect.lowercased()) else {
                return nil
            }
            return .init(action: action, resource: resource, effect: value)
        }
    }

    var version: Int
    var agent: String?
    var model: String?
    var plan: Bool?
    var goal: Bool?
    var verifyAfterEdits: Bool?
    var outputStyle: OutputStyle?
    var contextPaths: [String]?
    var allowedTools: [String]?
    var deniedTools: [String]?
    var permissions: [Permission]?

    static let fileNames = [".beetcode.json", ".beetcode.jsonc"]

    init(
        version: Int = 1,
        agent: String? = nil,
        model: String? = nil,
        plan: Bool? = nil,
        goal: Bool? = nil,
        verifyAfterEdits: Bool? = nil,
        outputStyle: OutputStyle? = nil,
        contextPaths: [String]? = nil,
        allowedTools: [String]? = nil,
        deniedTools: [String]? = nil,
        permissions: [Permission]? = nil
    ) {
        self.version = version
        self.agent = agent
        self.model = model
        self.plan = plan
        self.goal = goal
        self.verifyAfterEdits = verifyAfterEdits
        self.outputStyle = outputStyle
        self.contextPaths = contextPaths
        self.allowedTools = allowedTools
        self.deniedTools = deniedTools
        self.permissions = permissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        plan = try container.decodeIfPresent(Bool.self, forKey: .plan)
        goal = try container.decodeIfPresent(Bool.self, forKey: .goal)
        verifyAfterEdits = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterEdits)
        outputStyle = try container.decodeIfPresent(OutputStyle.self, forKey: .outputStyle)
        contextPaths = try container.decodeIfPresent([String].self, forKey: .contextPaths)
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
        deniedTools = try container.decodeIfPresent([String].self, forKey: .deniedTools)
        permissions = try container.decodeIfPresent([Permission].self, forKey: .permissions)
    }

    /// Returns the last policy file in the workspace root, preferring the
    /// normal JSON spelling. An invalid file is ignored so a typo cannot make
    /// an otherwise usable workspace fail to open.
    static func load(workspaceRoot: URL) -> ProjectPolicy? {
        for name in fileNames {
            let url = workspaceRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let data = jsonData(from: text),
                  let policy = try? JSONDecoder().decode(ProjectPolicy.self, from: data)
            else { continue }
            return policy
        }
        return nil
    }

    var openCodePermissions: OpenCodeCompatibility.OpenCodePermissionSet {
        OpenCodeCompatibility.OpenCodePermissionSet(
            rules: (permissions ?? []).compactMap(\.openCodeRule))
    }

    /// Enforces tool filters without weakening the normal approval gate.
    func includesTool(_ name: String) -> Bool {
        let denied = deniedTools ?? []
        if denied.contains(where: { Self.matches($0, value: name) }) { return false }
        guard let allowed = allowedTools, !allowed.isEmpty else { return true }
        return allowed.contains(where: { Self.matches($0, value: name) })
    }

    var hasToolFilter: Bool {
        !(allowedTools ?? []).isEmpty || !(deniedTools ?? []).isEmpty
    }

    /// Bounded prompt section for the active agent. Secrets are never read
    /// from this file and the text reminds the model which fields are policy,
    /// not user prose to copy into source files.
    var promptSection: String {
        var lines = [
            "Loaded from the workspace project policy (.beetcode.json).",
            "This file contains non-secret execution preferences; provider credentials stay in Keychain."
        ]
        if let agent, !agent.isEmpty { lines.append("Preferred agent: \(agent)") }
        if let model, !model.isEmpty { lines.append("Preferred model: \(model)") }
        if let outputStyle { lines.append("Answer style: \(outputStyle.rawValue)") }
        if let contextPaths, !contextPaths.isEmpty {
            lines.append("Prioritize context paths: \(contextPaths.joined(separator: ", "))")
        }
        if let allowedTools, !allowedTools.isEmpty {
            lines.append("Allowed tools: \(allowedTools.joined(separator: ", "))")
        }
        if let deniedTools, !deniedTools.isEmpty {
            lines.append("Denied tools: \(deniedTools.joined(separator: ", "))")
        }
        if let permissions, !permissions.isEmpty {
            let rules = permissions.map { "\($0.action):\($0.resource)=\($0.effect)" }
            lines.append("Permission rules: \(rules.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case version, agent, model, plan, goal, verifyAfterEdits
        case outputStyle, contextPaths, allowedTools, deniedTools, permissions
    }

    private static func matches(_ pattern: String, value: String) -> Bool {
        let pattern = Array(pattern.isEmpty ? "*" : pattern)
        let value = Array(value)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == value[valueIndex] || pattern[patternIndex] == "?" {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                starValueIndex = valueIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    /// Small JSONC reader for repository policy files. It removes comments
    /// only outside quoted strings and accepts trailing commas.
    private static func jsonData(from source: String) -> Data? {
        var output = ""
        let characters = Array(source)
        var index = 0
        var inString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                index += 2
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
            } else {
                output.append(character)
                index += 1
            }
        }

        guard let regex = try? NSRegularExpression(pattern: #",\s*([}\]])"#) else {
            return Data(output.utf8)
        }
        let range = NSRange(output.startIndex..., in: output)
        let normalized = regex.stringByReplacingMatches(
            in: output,
            range: range,
            withTemplate: "$1")
        return Data(normalized.utf8)
    }
}
