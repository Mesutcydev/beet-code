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
        let visible = stripped.split(whereSeparator: { $0.isWhitespace })
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
        return (visible, inOpenThink)
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