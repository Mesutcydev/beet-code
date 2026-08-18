import Foundation

/// Loads project agent instructions (the AGENTS.md / CLAUDE.md convention)
/// so every session starts with the project's own rules — build commands,
/// style, forbidden paths. Order of precedence when several exist:
/// AGENTS.md wins over CLAUDE.md; workspace files win over `~/.beetcode`.
/// Content is bounded so a runaway instructions file can't eat the context.
enum ProjectInstructions {

    static let maxCharacters = 8_000

    /// Candidate files in precedence order (first found wins).
    static func candidates(workspaceRoot: URL) -> [(label: String, url: URL)] {
        [
            ("workspace AGENTS.md", workspaceRoot.appendingPathComponent("AGENTS.md")),
            ("workspace CLAUDE.md", workspaceRoot.appendingPathComponent("CLAUDE.md")),
            ("user AGENTS.md", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".beetcode/AGENTS.md")),
            ("user CLAUDE.md", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".beetcode/CLAUDE.md")),
        ]
    }

    /// Returns the bounded instruction text plus the source label, or nil
    /// when no instructions file exists.
    static func load(workspaceRoot: URL) -> (text: String, source: String)? {
        for (label, url) in candidates(workspaceRoot: workspaceRoot) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > maxCharacters {
                let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
                return (String(trimmed[..<cutoff]) + "\n\n[truncated at \(maxCharacters) characters]", label)
            }
            return (trimmed, label)
        }
        return nil
    }

    /// Renders the section text injected into the system prompt.
    static func section(workspaceRoot: URL) -> String? {
        guard let (text, source) = load(workspaceRoot: workspaceRoot) else { return nil }
        return "Loaded from \(source). Follow these instructions; they override your defaults where they conflict.\n\n\(text)"
    }
}
