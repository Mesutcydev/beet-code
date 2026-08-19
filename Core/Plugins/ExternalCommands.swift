import Foundation

/// One slash-invocable capability discovered in a foreign tool's convention
/// directories — a Claude skill or command, a Codex prompt, or a native
/// BeetCode command. Invoking it expands the file's text into the next user
/// message, the same contract Claude Code and Codex give their own files.
struct ExternalCommand: Sendable, Equatable, Identifiable {
    enum Origin: String, Sendable {
        case claude = "Claude"
        case codex = "Codex"
        case beetcode = "Beet Code"
    }

    enum Kind: String, Sendable {
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

    var id: String { "\(origin.rawValue)-\(kind.rawValue)-\(name)" }
}

/// Universal compatibility discovery. Scans the convention directories of
/// every supported tool — Claude Code (`~/.claude/skills/*/SKILL.md`,
/// `~/.claude/commands/*.md`), Codex (`~/.codex/prompts/*.md`) and BeetCode's
/// own (`~/.beetcode/commands/*.md`), each mirrored per-workspace under the
/// same dot-directories — and normalizes what it finds into slash commands.
///
/// Precedence on a name collision: workspace beats home; within one scope,
/// the first origin in scan order wins (Claude, Codex, BeetCode).
enum ExternalCommands {

    static let maxCharacters = 8_000

    static func discover(home: URL, workspace: URL?) -> [ExternalCommand] {
        var commands: [ExternalCommand] = []
        var seen: Set<String> = []

        func add(name: String, origin: ExternalCommand.Origin, kind: ExternalCommand.Kind, url: URL) {
            let key = name.lowercased()
            guard !seen.contains(key),
                  let text = boundedText(url)
            else { return }
            seen.insert(key)
            commands.append(ExternalCommand(
                name: key, origin: origin, kind: kind, location: url, text: text))
        }

        // Scopes in precedence order: workspace first, then home.
        var scopes: [(root: URL, workspace: Bool)] = []
        if let workspace { scopes.append((workspace, true)) }
        scopes.append((home, false))

        for scope in scopes {
            // Claude skills: one SKILL.md per directory.
            let skillsDir = scope.root.appendingPathComponent(".claude/skills", isDirectory: true)
            for dir in directories(under: skillsDir) {
                let manifest = dir.appendingPathComponent("SKILL.md")
                add(name: dir.lastPathComponent, origin: .claude, kind: .skill, url: manifest)
            }
            // Claude commands: one .md per command.
            let claudeCommands = scope.root.appendingPathComponent(".claude/commands", isDirectory: true)
            for file in markdownFiles(under: claudeCommands) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .claude, kind: .command, url: file)
            }
            // Codex prompts.
            let codexPrompts = scope.root.appendingPathComponent(".codex/prompts", isDirectory: true)
            for file in markdownFiles(under: codexPrompts) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .codex, kind: .prompt, url: file)
            }
            // BeetCode native commands (same convention, our own home).
            let ownCommands = scope.root.appendingPathComponent(".beetcode/commands", isDirectory: true)
            for file in markdownFiles(under: ownCommands) {
                add(name: file.deletingPathExtension().lastPathComponent,
                    origin: .beetcode, kind: .command, url: file)
            }
        }

        return commands.sorted { $0.name < $1.name }
    }

    static func command(named name: String, home: URL, workspace: URL?) -> ExternalCommand? {
        let key = name.lowercased()
        return discover(home: home, workspace: workspace).first { $0.name == key }
    }

    // MARK: Helpers

    private static func directories(under root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private static func markdownFiles(under root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
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
