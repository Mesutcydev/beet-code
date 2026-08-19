import Foundation

/// Human titles for session rows. Import sources (especially Codex) often
/// stash hook tags (`<recommended_plugins>`) or environment wrappers as the
/// first "user" line — those must never become the list title.
enum SessionTitle {

    static func display(for record: SessionRecord) -> String {
        if let cleaned = meaningfulLine(in: record.title) {
            return cap(cleaned)
        }
        if let fromMessages = from(messages: record.messages) {
            return fromMessages
        }
        return fallback(for: record)
    }

    static func from(messages: [SessionMessage]) -> String? {
        for message in messages where message.role == .user {
            if let line = meaningfulLine(in: message.content) {
                return cap(line)
            }
        }
        for message in messages where message.role == .assistant {
            if let line = meaningfulLine(in: message.content) {
                return cap(line)
            }
        }
        return nil
    }

    /// First line that is real prose, not a source-tool wrapper.
    static func meaningfulLine(in raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = unwrapKnownTags(text)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !isNoise(trimmed) else { continue }
            return trimmed
        }
        return nil
    }

    static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("<") {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("<environment")
                || lower.hasPrefix("<user_instructions")
                || lower.hasPrefix("<system-reminder")
                || lower.hasPrefix("<system_reminder")
                || lower.hasPrefix("<recommended")
                || lower.hasPrefix("<permissions")
                || lower.hasPrefix("<mcp")
                || lower.hasPrefix("<plugin") {
                return true
            }
            // Bare tag: `<recommended_plugins>`
            if trimmed.hasSuffix(">") && !trimmed.contains(where: { $0.isWhitespace }) {
                return true
            }
        }
        return false
    }

    static func compactAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3600)))h" }
        if seconds < 86_400 * 14 { return "\(max(1, Int(seconds / 86_400)))d" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func unwrapKnownTags(_ text: String) -> String {
        let tags = ["user_query", "user-query", "task", "prompt"]
        for tag in tags {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            if let inner = slice(text, after: open, before: close) {
                return inner
            }
        }
        return text
    }

    private static func slice(_ text: String, after open: String, before close: String) -> String? {
        guard let start = text.range(of: open, options: .caseInsensitive),
              let end = text.range(of: close, options: .caseInsensitive, range: start.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : String(inner)
    }

    private static func cap(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }

    private static func fallback(for record: SessionRecord) -> String {
        let folder = URL(fileURLWithPath: record.workspacePath).lastPathComponent
        if !folder.isEmpty, folder != "/" {
            return "\(record.source.label) · \(folder)"
        }
        return "\(record.source.label) chat"
    }
}
