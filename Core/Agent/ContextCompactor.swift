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

    /// A request-level estimate that includes the system/tool protocol. The
    /// old message-only estimate could undercount a large system prompt and
    /// still let a remote provider reject a request before generation began.
    struct RequestEstimate: Sendable, Equatable {
        var historyTokens: Int
        var systemTokens: Int
        var totalTokens: Int
        var windowTokens: Int
        var responseReserve: Int

        var budgetTokens: Int {
            max(1, windowTokens - max(1_024, responseReserve))
        }

        var fraction: Double {
            Double(totalTokens) / Double(budgetTokens)
        }

        var shouldCompact: Bool {
            fraction > 0.75
        }

        var exceedsBudget: Bool {
            totalTokens > budgetTokens
        }
    }

    static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    static func estimate(messages: [SessionMessage], windowTokens: Int) -> Estimate {
        let total = contextBearingTokens(messages)
        return Estimate(totalTokens: total, windowTokens: windowTokens)
    }

    static func estimateRequest(
        messages: [SessionMessage],
        systemPrompt: String,
        windowTokens: Int,
        responseReserve: Int
    ) -> RequestEstimate {
        let historyTokens = contextBearingTokens(messages)
        let systemTokens = estimateTokens(systemPrompt)
        return RequestEstimate(
            historyTokens: historyTokens,
            systemTokens: systemTokens,
            totalTokens: historyTokens + systemTokens,
            windowTokens: windowTokens,
            responseReserve: responseReserve)
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

    /// Fits a compacted transcript into the request budget when tool-output
    /// replacement alone is not enough. This is the hard backstop for small
    /// local contexts and resumed sessions with many prose turns: keep the
    /// first user objective, the newest messages, and a visible omission
    /// marker instead of sending a request the provider must reject.
    static func fit(
        _ messages: [SessionMessage],
        systemPrompt: String,
        windowTokens: Int,
        responseReserve: Int
    ) -> [SessionMessage] {
        let budget = max(1_024, windowTokens - max(1_024, responseReserve))
        let systemTokens = estimateTokens(systemPrompt)
        // Leave room for the omission marker and provider tokenization
        // variance. The request estimate is intentionally conservative.
        let historyBudget = max(128, budget - systemTokens - 64)
        guard contextBearingTokens(messages) > historyBudget
                || estimateRequest(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    windowTokens: windowTokens,
                    responseReserve: responseReserve).exceedsBudget
        else { return messages }

        guard !messages.isEmpty else { return messages }

        let firstUserIndex = messages.firstIndex { $0.role == .user }
        var selectedIndices: [Int] = []
        var prepared: [Int: SessionMessage] = [:]
        var used = 0

        if let firstUserIndex {
            let first = messages[firstUserIndex]
            let kept = boundedMessage(first, maxTokens: min(estimateTokens(first.content), historyBudget / 3))
            selectedIndices.append(firstUserIndex)
            prepared[firstUserIndex] = kept
            used += estimateTokens(kept.content)
        }

        var tail: [(index: Int, message: SessionMessage)] = []
        for index in messages.indices.reversed()
            where index != firstUserIndex && messages[index].role != .reasoning {
            let message = messages[index]
            let remaining = historyBudget - used
            guard remaining > 0 else { break }
            let kept = boundedMessage(message, maxTokens: remaining)
            let cost = estimateTokens(kept.content)
            guard cost > 0 else { continue }
            tail.append((index, kept))
            prepared[index] = kept
            used += cost
            if cost < estimateTokens(message.content) { break }
        }

        selectedIndices.append(contentsOf: tail.map(\.index))
        selectedIndices = Array(
            Set(selectedIndices + requiredToolPairingIndices(
                in: messages,
                selected: selectedIndices))).sorted()

        var result: [SessionMessage] = []
        var insertedMarker = false
        for index in selectedIndices {
            if !insertedMarker,
               let first = selectedIndices.first,
               index != first,
               messages.distance(from: first, to: index) > 1 {
                result.append(SessionMessage(
                    role: .user,
                    content: "[Earlier conversation omitted to preserve context; the newest work is kept below.]",
                    toolName: nil,
                    timestamp: messages[index].timestamp))
                insertedMarker = true
            }
            result.append(prepared[index] ?? messages[index])
        }

        return result.isEmpty ? [messages.last!] : result
    }

    /// Reasoning summaries are durable transcript rows, but they are not
    /// replayed to the model. Excluding them from the budget keeps a visible
    /// thought history from triggering another provider-side context error.
    private static func contextBearingTokens(_ messages: [SessionMessage]) -> Int {
        messages.reduce(0) { total, message in
            guard message.role != .reasoning else { return total }
            return total + estimateTokens(message.content)
        }
    }

    private static func boundedMessage(
        _ message: SessionMessage,
        maxTokens: Int
    ) -> SessionMessage {
        let maxCharacters = max(64, maxTokens * 4)
        guard message.content.count > maxCharacters else { return message }
        var bounded = message
        let marker = "\n…[middle of message omitted]…\n"
        let half = max(1, (maxCharacters - marker.count) / 2)
        bounded.content = String(message.content.prefix(half))
            + marker
            + String(message.content.suffix(half))
        return bounded
    }

    /// Tool observations are only meaningful with the assistant turn that
    /// requested them. A tail-only fit can otherwise select the newest result
    /// while dropping its assistant/tool-call pair, producing invalid replay
    /// history on the next generation.
    private static func requiredToolPairingIndices(
        in messages: [SessionMessage],
        selected: [Int]
    ) -> [Int] {
        var required = Set<Int>()
        for index in selected {
            guard messages[index].role == .toolResult || messages[index].role == .toolCall else {
                continue
            }
            var callIndex: Int?
            if messages[index].role == .toolCall {
                callIndex = index
            } else {
                callIndex = messages[..<index].lastIndex { $0.role == .toolCall }
            }
            guard let callIndex else { continue }
            guard let assistantIndex = messages[..<callIndex].lastIndex(where: { $0.role == .assistant }) else {
                continue
            }
            required.insert(assistantIndex)
            required.insert(callIndex)
        }
        return required.filter { !selected.contains($0) }
    }
}
