import Foundation

/// Pure streaming-display filter for the transcript card.
///
/// Two failure modes it eliminates:
/// 1. **Raw reasoning leaks** — deltas stream verbatim, so `<think>…` blocks
///    (complete or still open) were visible mid-generation. The accumulated
///    raw text is run through `PromptBuilder.strippingThinking`, which
///    removes complete blocks AND unterminated ones.
/// 2. **Repetition filler loops** — small local models sometimes emit
///    "thinking thinking thinking…" instead of real content. A tail of the
///    same word repeated 4+ times is treated as reasoning, hidden from the
///    transcript, and surfaced as a proper "Reasoning…" indicator.
enum StreamDisplayFilter {

    /// The visible portion of what has streamed so far, plus whether the
    /// model currently appears to be reasoning.
    static func display(raw: String) -> (visible: String, reasoning: Bool) {
        let stripped = PromptBuilder.strippingThinking(raw)
        // Tool-call syntax is wire format, never transcript content: strip
        // complete calls and hide the tail of one still streaming in, so
        // raw JSON/fenced blocks can never flash on screen.
        let prose = cuttingUnterminatedToolTail(ToolParser.strippingCalls(from: stripped))
        let visible = prose.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if hasRepetitionFillerTail(visible) {
            return (trimmingFillerTail(visible), true)
        }
        var inOpenThink = false
        var searchFrom = raw.startIndex
        while searchFrom < raw.endIndex {
            guard let open = raw.range(
                of: "<think>",
                range: searchFrom..<raw.endIndex)
            else { break }
            inOpenThink = raw[open.upperBound...]
                .range(of: "</think>") == nil
            searchFrom = open.upperBound
        }
        // 思考 markers pair up like delimiters (see PromptBuilder
        // .strippingThinking): an odd count means the last one is still open.
        if !inOpenThink {
            var markers = 0
            var from = raw.startIndex
            while let m = raw.range(of: "思考", range: from..<raw.endIndex) {
                markers += 1
                from = m.upperBound
            }
            inOpenThink = markers % 2 == 1
        }
        // Everything streamed so far is think/tool wire format — show the
        // working indicator instead of an empty or raw-JSON bubble.
        if visible.isEmpty, !stripped.isEmpty {
            return ("", true)
        }
        return (visible, inOpenThink)
    }

    /// Cuts a still-streaming tool call off the tail: an unterminated
    /// tool/json fence, an open `<tool_call>` tag, or a `{"name": …` object
    /// whose braces have not balanced yet. Legitimate code fences (```swift
    /// etc.) are left alone — only tool-shaped content is hidden.
    private static func cuttingUnterminatedToolTail(_ text: String) -> String {
        // Unterminated fence whose info string or body marks it as a call.
        let fences = text.components(separatedBy: "```").count - 1
        if fences % 2 == 1, let open = text.range(of: "```", options: .backwards) {
            let tail = String(text[open.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let info = tail.prefix(8).lowercased()
            if info.hasPrefix("tool") || info.hasPrefix("json") || tail.hasPrefix("{") {
                return String(text[..<open.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Open <tool_call> without its close tag.
        if let tagOpen = text.range(of: "<tool_call>", options: .backwards) {
            let after = text[tagOpen.upperBound...]
            if !after.contains("</tool_call>") {
                return String(text[..<tagOpen.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Trailing unbalanced {"name": … object.
        if ToolParser.looksLikeToolCallFragment(text),
           let regex = try? NSRegularExpression(pattern: #"\{\s*"name"\s*:"#) {
            let nsRange = NSRange(text.startIndex..., in: text)
            if let last = regex.matches(in: text, range: nsRange).last,
               let range = Range(last.range, in: text) {
                return String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "thinking thinking thinking …" — the same word (2–12 chars) repeated
    /// 4+ times at the tail, whitespace-separated.
    static func hasRepetitionFillerTail(_ text: String) -> Bool {
        let tail = String(text.suffix(96))
        let words = tail.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return false }
        let last = normalize(words[words.count - 1])
        guard last.count >= 2, last.count <= 12 else { return false }
        var matches = 0
        for word in words.reversed() {
            if normalize(word) == last { matches += 1 } else { break }
        }
        return matches >= 4
    }

    /// Removes the repeating word (and separating whitespace) from the end.
    static func trimmingFillerTail(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let lastWord = words.last else { return text }
        let needle = normalize(lastWord)
        var kept = Array(words)
        while let w = kept.last, normalize(w) == needle {
            kept.removeLast()
        }
        return kept.joined(separator: " ")
    }

    private static func normalize(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}