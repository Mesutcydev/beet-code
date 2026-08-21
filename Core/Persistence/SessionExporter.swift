import Foundation

/// Renders a session record as a shareable document. Markdown is the
/// human-readable export; JSON is the lossless one (the encrypted on-disk
/// record, decoded). Tool-call wire format is sanitized out of assistant
/// text — an export reads as a conversation, not a protocol dump.
enum SessionExporter {

    enum Format: String, CaseIterable {
        case markdown
        case json

        var label: String {
            switch self {
            case .markdown: "Markdown (.md)"
            case .json: "JSON (.json)"
            }
        }

        var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
    }

    static func markdown(for record: SessionRecord) -> String {
        var lines: [String] = []
        let stamp = DateFormatter.exportStamp

        lines.append("# \(record.title)")
        lines.append("")
        lines.append("- Source: \(record.source.label)")
        lines.append("- Workspace: \(record.workspacePath.isEmpty ? "—" : record.workspacePath)")
        if !record.modelID.isEmpty { lines.append("- Model: \(record.modelID)") }
        lines.append("- Exported: \(stamp.string(from: Date()))")
        lines.append("")
        lines.append("---")

        let time = DateFormatter.exportTime
        for message in record.messages {
            switch message.role {
            case .user:
                lines.append("")
                lines.append("## You · \(time.string(from: message.timestamp))")
                lines.append("")
                lines.append(message.content)
            case .assistant:
                let prose = ToolParser.strippingCalls(
                    from: PromptBuilder.cleaningGeneratedText(message.content))
                guard !prose.isEmpty else { continue }
                lines.append("")
                lines.append("## \(record.source == .app ? "Beet Code" : record.source.label) · \(time.string(from: message.timestamp))")
                lines.append("")
                lines.append(prose)
            case .reasoning:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines.append("")
                lines.append("<details>")
                lines.append("<summary>Reasoning summary · \(time.string(from: message.timestamp))</summary>")
                lines.append("")
                lines.append(message.content)
                lines.append("")
                lines.append("</details>")
            case .toolCall:
                lines.append("")
                lines.append("> 🔧 `\(message.toolName ?? "tool")`")
            case .toolResult:
                let failed = message.content.hasPrefix("error:") || message.content == "declined by user"
                let output = message.content.count > 2000
                    ? String(message.content.prefix(2000)) + "\n… (truncated)"
                    : message.content
                lines.append("")
                lines.append("> \(failed ? "✗" : "✓") result")
                lines.append(">")
                for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
                }
            case .system:
                continue
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func json(for record: SessionRecord) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(record)
    }

    /// A filesystem-safe export filename: title slug + short date.
    static func suggestedName(for record: SessionRecord, format: Format) -> String {
        let slug = record.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        let date = DateFormatter.exportDay.string(from: record.updatedAt)
        return "\(slug.isEmpty ? "chat" : slug)-\(date).\(format.fileExtension)"
    }
}

private extension DateFormatter {
    static let exportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    static let exportTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let exportDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
