import Foundation

/// Slash commands typed in the composer: local-first shortcuts over
/// primitives the loop already exposes (plan mode, undo, compaction, model
/// switching, memory). They execute IMMEDIATELY in the UI/controller layer —
/// they never consume an agent turn.
enum SlashCommand: Equatable {
    case plan
    case auto
    case goal
    case undo
    case compact
    case model(String)      // argument: model id
    case memory             // list facts
    case memoryAdd(String)  // argument: fact text
    case help
    case unknown(String)

    /// Parses composer text; returns nil for ordinary messages.
    static func parse(_ raw: String) -> SlashCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return .help }
        let command = String(first).lowercased()
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch command {
        case "plan": return .plan
        case "auto": return .auto
        case "goal": return .goal
        case "undo": return .undo
        case "compact": return .compact
        case "model":
            return argument.isEmpty ? .help : .model(argument)
        case "memory":
            if argument == "add" || argument.hasPrefix("add ") {
                let fact = argument.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                return fact.isEmpty ? .help : .memoryAdd(fact)
            }
            return .memory
        case "help": return .help
        default: return .unknown(text)
        }
    }

    /// The catalog shown by /help — must stay in sync with parse().
    static let helpText = """
    Slash commands:
      /plan        Toggle plan mode (agent plans first, you approve)
      /auto        Use direct task mode with normal approval gates
      /goal        Use goal mode: plan first, then work until complete
      /undo        Restore the workspace to the last checkpoint
      /compact     Compress this session's history now
      /model <id>  Switch the active model (see Model Manager for ids)
      /memory      List stored workspace facts
      /memory add <text>  Store a durable fact
      /help        Show this list
    """
}
