import Foundation

/// How aggressively old tool outputs are compacted (v0.3).
enum CompressionLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case light
    case standard
    case aggressive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .standard: "Standard"
        case .aggressive: "Aggressive"
        }
    }

    /// How many recent tool results keep their full content.
    var keepRecent: Int {
        switch self {
        case .light: 6
        case .standard: 3
        case .aggressive: 1
        }
    }

    /// Maximum characters kept per preserved tool result in aggressive mode.
    var maxToolResultChars: Int? {
        switch self {
        case .aggressive: 2_000
        case .light, .standard: nil
        }
    }
}

/// Keeps transcripts within the model's context window by collapsing old tool
/// outputs. Token counts are estimated (≈4 characters per token) which is
/// accurate enough for deciding *when* to compact.
enum ContextCompactor {

    struct Estimate: Sendable, Equatable {
        var totalTokens: Int
        var windowTokens: Int
        var fraction: Double { windowTokens > 0 ? Double(totalTokens) / Double(windowTokens) : 1 }
        var shouldCompact: Bool { fraction > 0.75 }
    }

    static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    static func estimate(messages: [SessionMessage], windowTokens: Int) -> Estimate {
        let total = messages.reduce(0) { $0 + estimateTokens($1.content) }
        return Estimate(totalTokens: total, windowTokens: windowTokens)
    }

    /// Replaces the content of old tool results (keeping the most recent
    /// `keepRecent`) with a stub. User/assistant messages are never dropped.
    /// Aggressive levels additionally truncate the preserved results.
    static func compact(
        _ messages: [SessionMessage],
        keepRecent: Int = 3,
        maxToolResultChars: Int? = nil
    ) -> [SessionMessage] {
        // Indices of tool results, newest last.
        let toolResultIndices = messages.enumerated()
            .filter { $0.element.role == .toolResult }
            .map(\.offset)
        let preserved = Set(toolResultIndices.suffix(keepRecent))
        let stubbed = Set(toolResultIndices).subtracting(preserved)

        guard !stubbed.isEmpty else { return messages }

        return messages.enumerated().map { index, message in
            if stubbed.contains(index) {
                var collapsed = message
                collapsed.content = "[older tool output omitted to save context]"
                return message == collapsed ? message : collapsed
            }
            // Aggressive mode bounds even preserved tool outputs.
            if let maxToolResultChars,
               message.role == .toolResult,
               message.content.utf8.count > maxToolResultChars {
                var bounded = message
                bounded.content = String(message.content.prefix(maxToolResultChars))
                    + "\n…[output truncated by aggressive compression]…"
                return bounded
            }
            return message
        }
    }
}