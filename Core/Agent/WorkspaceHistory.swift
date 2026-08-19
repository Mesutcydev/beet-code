import Foundation

/// Workspace-aware session history: reads every session that belongs to the
/// selected project folder — BeetCode's own AND chats imported from Claude,
/// Codex and Cursor — and distills them into a bounded digest the agent
/// receives as system-prompt context. The same idea as Claude Code reading
/// a project's past sessions, but across every tool the user has used here.
enum WorkspaceHistory {

    /// Digest bounding: the section must inform, not eat the context window.
    static let maxSessions = 8
    static let maxCharacters = 1_600

    /// Sessions belonging to this workspace folder, newest first, capped.
    /// Reads through the store's TTL cache so a run never pays a
    /// decrypt-every-file pass for the digest.
    static func sessions(workspacePath: String, store: SessionStore = .shared) -> [SessionRecord] {
        Array(store.cachedAll()
            .filter { $0.workspacePath == workspacePath }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxSessions))
    }

    /// System-prompt section summarizing earlier work in this folder, or nil
    /// when there is none. Own sessions and imported chats count equally —
    /// the agent learns what was discussed here regardless of the tool.
    static func section(workspacePath: String, store: SessionStore = .shared) -> String? {
        let matches = sessions(workspacePath: workspacePath, store: store)
        guard !matches.isEmpty else { return nil }

        var counts: [SessionSource: Int] = [:]
        for record in matches { counts[record.source, default: 0] += 1 }
        let breakdown = SessionSource.allCases
            .compactMap { source -> String? in
                guard let count = counts[source], count > 0 else { return nil }
                return "\(count) \(source.label)"
            }
            .joined(separator: ", ")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // One line per session: source, date, and the first thing the user
        // asked — the cheapest honest topic signal there is.
        var lines: [String] = []
        var length = 0
        for record in matches {
            let firstUser = record.messages.first(where: { $0.role == .user })?.content
                .split(separator: "\n").first.map(String.init) ?? record.title
            let topic = firstUser.count > 90 ? String(firstUser.prefix(90)) + "…" : firstUser
            let line = "- [\(record.source.label), \(formatter.string(from: record.updatedAt))] \(topic)"
            guard length + line.count + 1 <= maxCharacters else { break }
            lines.append(line)
            length += line.count + 1
        }
        guard !lines.isEmpty else { return nil }

        return """
        Earlier sessions in this workspace (\(matches.count) shown: \(breakdown)). \
        These are past conversations — BeetCode's own and ones imported from other \
        tools. Treat them as background only; verify anything before relying on it:
        \(lines.joined(separator: "\n"))
        """
    }
}
