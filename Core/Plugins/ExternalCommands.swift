import Foundation

/// One slash-invocable capability discovered in a foreign tool's convention
/// directories — a Claude skill or command, a Codex prompt, or a native
/// BeetCode command. Invoking it expands the file's text into the next user
/// message, the same contract Claude Code and Codex give their own files.
struct ExternalCommand: Sendable, Equatable, Identifiable {
    enum Origin: String, Sendable, Hashable {
        case claude = "Claude"
        case codex = "Codex"
        case cursor = "Cursor"
        case copilot = "GitHub Copilot"
        case windsurf = "Windsurf"
        case agent = "Agent Skills"
        case beetcode = "Beet Code"
        case openCode = "OpenCode"
        case external = "Added Folder"
    }

    enum Kind: String, Sendable, Hashable {
        case skill
        case command
        case prompt

        var label: String { rawValue }
    }

    /// Slash name (lowercased, no leading slash): skill directory or file basename.
    let name: String
    let origin: Origin
    let kind: Kind
    let location: URL
    let text: String
    let description: String?
    let agent: String?
    let model: String?
    let subtask: Bool

    var id: String { "\(origin.rawValue)-\(kind.rawValue)-\(name)" }

    func render(arguments: String) -> String {
        let parts = arguments.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var result = text.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        for (index, value) in parts.enumerated() {
            result = result.replacingOccurrences(of: "$\(index + 1)", with: value)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Universal compatibility discovery. Scans the convention directories of
/// every supported tool — Claude Code, Codex, Cursor, Copilot, Windsurf,
/// OpenCode and the shared Agent Skills convention — then normalizes what it
/// finds into slash commands. Plugin bundles remain inert: only their
/// Markdown skills, commands, prompts and workflows are read.
///
/// Precedence on a name collision: workspace beats home; within one scope,
/// the first origin in scan order wins (Claude, Codex, BeetCode).
enum ExternalCommands {

    static let maxCharacters = 8_000

    static func discover(
        home: URL,
        workspace: URL?,
        additionalRoots: [URL] = []
    ) -> [ExternalCommand] {
        var commands: [ExternalCommand] = []
        var seen: Set<String> = []

        func add(
            name: String,
            origin: ExternalCommand.Origin,
            kind: ExternalCommand.Kind,
            url: URL,
            description: String? = nil,
            agent: String? = nil,
            model: String? = nil,
            subtask: Bool = false,
            textOverride: String? = nil
        ) {
            let key = name.lowercased()
            guard !seen.contains(key),
                  let text = textOverride ?? boundedText(url)
            else { return }
            seen.insert(key)
            commands.append(ExternalCommand(
                name: key,
                origin: origin,
                kind: kind,
                location: url,
                text: text,
                description: description,
                agent: agent,
                model: model,
                subtask: subtask))
        }

        // Scopes in precedence order: workspace first, then home.
        var scopes: [(root: URL, workspace: Bool)] = []
        if let workspace { scopes.append((workspace, true)) }
        scopes.append((home, false))

        for scope in scopes {
            addSkills(relativePath: ".claude/skills", origin: .claude, scope: scope.root, add: add)
            // Claude commands: one .md per command.
            let claudeCommands = scope.root.appendingPathComponent(".claude/commands", isDirectory: true)
            for file in markdownFiles(under: claudeCommands) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .claude, kind: .command, url: file)
            }
            // Codex supports first-class skills as well as legacy prompts.
            addSkills(relativePath: ".codex/skills", origin: .codex, scope: scope.root, add: add)
            let codexPrompts = scope.root.appendingPathComponent(".codex/prompts", isDirectory: true)
            for file in markdownFiles(under: codexPrompts) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .codex, kind: .prompt, url: file)
            }
            // Plugin bundles can carry skills. Import the declarative skill
            // surface only; manifests, hooks and executables are never run.
            addSkills(relativePath: ".claude/plugins", origin: .claude, scope: scope.root, add: add)
            addSkills(relativePath: ".codex/plugins", origin: .codex, scope: scope.root, add: add)

            addSkills(relativePath: ".cursor/skills", origin: .cursor, scope: scope.root, add: add)
            addMarkdown(relativePath: ".cursor/commands", origin: .cursor,
                        kind: .command, scope: scope.root, add: add)
            addSkills(relativePath: ".cursor/plugins", origin: .cursor, scope: scope.root, add: add)

            addSkills(relativePath: ".github/skills", origin: .copilot, scope: scope.root, add: add)
            addMarkdown(relativePath: ".github/prompts", origin: .copilot,
                        kind: .prompt, scope: scope.root, add: add)

            addSkills(relativePath: ".windsurf/skills", origin: .windsurf, scope: scope.root, add: add)
            addMarkdown(relativePath: ".windsurf/workflows", origin: .windsurf,
                        kind: .command, scope: scope.root, add: add)

            addSkills(relativePath: ".agents/skills", origin: .agent, scope: scope.root, add: add)
            addSkills(relativePath: ".agent/skills", origin: .agent, scope: scope.root, add: add)
            // BeetCode native commands (same convention, our own home).
            let ownCommands = scope.root.appendingPathComponent(".beetcode/commands", isDirectory: true)
            for file in markdownFiles(under: ownCommands) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .beetcode, kind: .command, url: file)
            }
        }

        // OpenCode commands can be Markdown files or JSON command entries.
        // The compatibility reader already applies project-over-global
        // precedence and resolves bounded templates; expose the same command
        // through Beet Code's slash-command surface.
        let openCode = OpenCodeCompatibility.load(home: home, workspace: workspace)
        for command in openCode.commands {
            add(
                name: command.name,
                origin: .openCode,
                kind: .command,
                url: command.sourceURL,
                description: command.description,
                agent: command.agent,
                model: command.model,
                subtask: command.subtask,
                textOverride: command.template)
        }

        // User-added IDE or plugin folders use the same conservative reader.
        // A selected skill directory, a plugin bundle, or an IDE config root
        // all work without copying or executing anything from that folder.
        for root in additionalRoots where isDirectory(root) {
            for manifest in skillManifests(under: root) {
                add(name: manifest.deletingLastPathComponent().lastPathComponent,
                    origin: .external, kind: .skill, url: manifest)
            }
            for file in reusableMarkdownFiles(under: root) {
                let parent = file.deletingLastPathComponent().lastPathComponent.lowercased()
                let kind: ExternalCommand.Kind = parent.contains("prompt") ? .prompt : .command
                add(name: commandName(for: file), origin: .external, kind: kind, url: file)
            }
        }

        return commands.sorted { $0.name < $1.name }
    }

    static func command(
        named name: String,
        home: URL,
        workspace: URL?,
        additionalRoots: [URL] = []
    ) -> ExternalCommand? {
        let key = name.lowercased()
        return discover(home: home, workspace: workspace, additionalRoots: additionalRoots)
            .first { $0.name == key }
    }

    // MARK: Helpers

    private static let maxDiscoveredFiles = 400

    private static func addSkills(
        relativePath: String,
        origin: ExternalCommand.Origin,
        scope: URL,
        add: (String, ExternalCommand.Origin, ExternalCommand.Kind, URL,
              String?, String?, String?, Bool, String?) -> Void
    ) {
        let root = scope.appendingPathComponent(relativePath, isDirectory: true)
        for manifest in skillManifests(under: root) {
            add(manifest.deletingLastPathComponent().lastPathComponent,
                origin, .skill, manifest, nil, nil, nil, false, nil)
        }
    }

    private static func addMarkdown(
        relativePath: String,
        origin: ExternalCommand.Origin,
        kind: ExternalCommand.Kind,
        scope: URL,
        add: (String, ExternalCommand.Origin, ExternalCommand.Kind, URL,
              String?, String?, String?, Bool, String?) -> Void
    ) {
        let root = scope.appendingPathComponent(relativePath, isDirectory: true)
        for file in markdownFiles(under: root) {
            add(commandName(for: file), origin, kind, file, nil, nil, nil, false, nil)
        }
    }

    private static func markdownFiles(under root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private static func skillManifests(under root: URL) -> [URL] {
        guard isDirectory(root), let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true })
        else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
               isDirectory(url) {
                enumerator.skipDescendants()
            }
            guard url.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame else { continue }
            results.append(url)
            if results.count >= maxDiscoveredFiles { break }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func reusableMarkdownFiles(under root: URL) -> [URL] {
        guard isDirectory(root), let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true })
        else { return [] }
        let supportedParents = ["commands", "command", "prompts", "prompt", "workflows", "workflow"]
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard url.lastPathComponent.caseInsensitiveCompare("SKILL.md") != .orderedSame else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
            guard supportedParents.contains(parent) else { continue }
            results.append(url)
            if results.count >= maxDiscoveredFiles { break }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func commandName(for file: URL) -> String {
        var name = file.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".prompt") { name.removeLast(".prompt".count) }
        return name
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func boundedText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCharacters else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<cutoff]) + "\n\n[truncated at \(maxCharacters) characters]"
    }
}
