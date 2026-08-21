import Foundation

/// One tool call extracted from raw model output.
struct ParsedToolCall: Sendable, Equatable, Identifiable {
    let name: String
    let arguments: LFJSONValue
    let index: Int

    var id: String { "\(name)#\(index)" }

    /// Canonical JSON for execution/logging.
    var argumentsJSON: String { arguments.encoded() }

    /// Convenience accessors used by tools.
    func string(_ key: String) -> String? {
        arguments.objectValue?[key]?.stringValue
            ?? arguments.objectValue?[key]?.numberValue.map { String($0) }
    }

    func int(_ key: String) -> Int? {
        arguments.objectValue?[key]?.intValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap(Int.init)
    }

    func number(_ key: String) -> Double? {
        arguments.objectValue?[key]?.numberValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap(Double.init)
    }

    func bool(_ key: String) -> Bool? {
        arguments.objectValue?[key]?.boolValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap { $0.lowercased() == "true" ? true : ($0.lowercased() == "false" ? false : nil) }
    }

    /// String arrays (e.g. modifier lists). A bare string is treated as a
    /// one-element array — models often emit `"modifiers": "cmd"`.
    func strings(_ key: String) -> [String] {
        if let array = arguments.objectValue?[key]?.arrayValue {
            return array.compactMap(\.stringValue)
        }
        if let single = arguments.objectValue?[key]?.stringValue {
            return [single]
        }
        return []
    }
}

/// Extracts tool calls from raw model text. Completely independent of the
/// inference engine — the pipeline is:
///
///     raw text → block extractor → tolerant JSON normalization → shape validation
///
/// Guided generation, when enabled later, is an optimization that makes calls
/// well-formed before they reach this parser; it is never a dependency.
///
/// Recognized formats (in priority order of appearance, all merged):
/// 1. Fenced blocks:      ```tool { "name": …, "arguments": {…} } ```
/// 2. Qwen native tags:   <tool_call>{ "name": …, "arguments": {…} }</tool_call>
/// 3. OpenAI envelopes:   { "tool_calls": [ { "function": { "name": … } } ] }
/// 4. Bare JSON objects containing a "name" key (last resort)
enum ToolParser {

    struct Candidate: Equatable {
        let range: Range<String.Index>
        let payload: String
        /// The complete wire-format container, when the payload came from a
        /// fenced block or `<tool_call>` wrapper. Parsing only needs `range`,
        /// while display cleanup must remove the wrapper as well.
        let containerRange: Range<String.Index>?
    }

    static func parse(_ text: String) -> [ParsedToolCall] {
        let candidates = collectCandidates(text)
        var calls: [ParsedToolCall] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let value = TolerantJSON.value(from: candidate.payload) else { continue }
            for call in shape(value) where !seen.contains(call.signature) {
                seen.insert(call.signature)
                calls.append(
                    ParsedToolCall(
                        name: call.name,
                        arguments: call.arguments,
                        index: calls.count))
            }
        }
        return calls
    }

    // MARK: Extraction

    private static func collectCandidates(_ text: String) -> [Candidate] {
        var candidates: [Candidate] = []

        // 1. Fenced code blocks whose info string mentions tool/json, or whose
        //    body starts with '{'.
        if let regex = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_-]*[ \\t]*\\n?([\\s\\S]*?)```") {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let payloadRange = Range(match.range(at: 1), in: text)
                else { continue }
                let payload = text[payloadRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload.hasPrefix("{") else { continue }
                candidates.append(Candidate(
                    range: payloadRange,
                    payload: payload,
                    containerRange: Range(match.range, in: text)))
            }
        }

        // 2. <tool_call> XML wrappers (Qwen).
        if let regex = try? NSRegularExpression(pattern: #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                if let payloadRange = Range(match.range(at: 1), in: text) {
                    candidates.append(Candidate(
                        range: payloadRange,
                        payload: String(text[payloadRange]),
                        containerRange: Range(match.range, in: text)))
                }
            }
        }

        // 3/4. Bare balanced JSON objects — only where nothing else claimed the range.
        candidates.append(contentsOf: bareObjects(in: text, excluding: candidates.map(\.range)))

        // Order by appearance, drop overlaps (fenced beats bare).
        candidates.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result: [Candidate] = []
        var claimed: [Range<String.Index>] = []
        for candidate in candidates {
            let overlaps = claimed.contains { $0.overlaps(candidate.range) }
            if !overlaps {
                result.append(candidate)
                claimed.append(candidate.range)
            }
        }
        return result
    }

    /// Byte-depth scan for balanced `{ … }` regions outside already-claimed ranges.
    private static func bareObjects(in text: String, excluding claimed: [Range<String.Index>]) -> [Candidate] {
        var candidates: [Candidate] = []
        var depth = 0
        var start: String.Index?

        for index in text.indices {
            let character = text[index]
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth = max(0, depth - 1)
                if depth == 0, let objectStart = start {
                    let range = objectStart..<text.index(after: index)
                    let overlaps = claimed.contains { $0.overlaps(range) }
                    if !overlaps {
                        candidates.append(Candidate(
                            range: range,
                            payload: String(text[range]),
                            containerRange: nil))
                    }
                    start = nil
                }
            }
        }
        return candidates
    }

    /// Removes an empty `<tool_call>` wrapper without touching a valid call,
    /// so the agent loop can still parse any real tool request that follows.
    static func strippingEmptyCallWrappers(from text: String) -> String {
        let ranges = emptyCallWrapperRanges(in: text)
        guard !ranges.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return removing(ranges: ranges, from: text)
    }

    /// Removes everything that parses as a tool call (fenced blocks,
    /// `<tool_call>` tags, bare JSON) from display text, leaving only prose.
    /// Used to sanitize assistant messages for the transcript: the model's
    /// raw call syntax is wire format, never user-facing content.
    static func strippingCalls(from text: String) -> String {
        var removals: [Range<String.Index>] = []
        for candidate in collectCandidates(text) {
            guard let value = TolerantJSON.value(from: candidate.payload),
                  !shape(value).isEmpty else { continue }
            removals.append(candidate.containerRange ?? candidate.range)
        }
        // A model can emit an empty wrapper while deciding whether to call a
        // tool. It is still protocol noise, and leaving the tags behind makes
        // the final answer look like a broken XML transcript.
        removals.append(contentsOf: emptyCallWrapperRanges(in: text))
        guard !removals.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return removing(ranges: removals, from: text)
    }

    private static func emptyCallWrapperRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<tool_call>\s*</tool_call>"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text)
        }
    }

    private static func removing(
        ranges: [Range<String.Index>],
        from text: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        var lastRemovedEnd: String.Index?
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            // A valid wrapper and an empty-wrapper cleanup can overlap only
            // when a malformed provider repeats tags. Avoid duplicating the
            // intervening text if that happens.
            if let lastRemovedEnd, range.lowerBound < lastRemovedEnd { continue }
            result += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            lastRemovedEnd = range.upperBound
        }
        result += text[cursor...]
        // Collapse the blank runs a removed block leaves behind.
        let collapsed = result.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text ends inside what looks like an UNTERMINATED tool
    /// call: a `{"name": …` object whose braces never balance (the token
    /// ceiling cut the JSON off mid-call). Such a reply executed nothing —
    /// the loop should treat it as a protocol error, not a final answer.
    static func looksLikeToolCallFragment(_ text: String) -> Bool {
        guard let match = try? NSRegularExpression(pattern: #"\{\s*"name"\s*:"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return false }
        let tail = text[range.lowerBound...]
        var depth = 0
        var inString = false
        var escaped = false
        for character in tail {
            if escaped { escaped = false; continue }
            if escaped == false, character == "\\", inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
        }
        return depth > 0
    }

    // MARK: Shape validation

    private struct Shaped: Equatable {
        let name: String
        let arguments: LFJSONValue
        var signature: String { name + "|" + arguments.encoded() }
    }

    /// Validates the normalized value is shaped like a tool call; accepts
    /// `name`+(`arguments`|`args`|`parameters`|`input`), OpenAI `tool_calls`
    /// envelopes, and `{"function": {"name": …, "arguments": …}}`.
    private static func shape(_ value: LFJSONValue) -> [Shaped] {
        guard let object = value.objectValue else { return [] }

        if let toolCalls = object["tool_calls"]?.arrayValue {
            return toolCalls.compactMap { entry in
                guard let entryObject = entry.objectValue else { return nil }
                let function = entryObject["function"]?.objectValue
                let name = function?["name"]?.stringValue ?? entryObject["name"]?.stringValue
                guard let name, !name.isEmpty else { return nil }
                let arguments = function?["arguments"] ?? entryObject["arguments"]
                return Shaped(name: name, arguments: coerceArguments(arguments))
            }
        }

        if let function = object["function"]?.objectValue,
           let name = function["name"]?.stringValue,
           !name.isEmpty
        {
            return [Shaped(name: name, arguments: coerceArguments(function["arguments"]))]
        }

        guard let name = object["name"]?.stringValue, !name.isEmpty else { return [] }
        let arguments = coerceArguments(
            object["arguments"] ?? object["args"] ?? object["parameters"] ?? object["input"])
        return [Shaped(name: name, arguments: arguments)]
    }

    /// Models sometimes emit arguments as a JSON *string* rather than an object.
    private static func coerceArguments(_ value: LFJSONValue?) -> LFJSONValue {
        guard let value else { return .object([:]) }
        if case .object = value { return value }
        if let text = value.stringValue, let inner = TolerantJSON.value(from: text) {
            if case .object = inner { return inner }
        }
        return .object([:])
    }
}

private extension ParsedToolCall {
    var signature: String { name + "|" + argumentsJSON }
}

/// Wire-format serializer for tool calls — the inverse of `ToolParser.parse`.
/// Engines that receive tool calls as structured events instead of text
/// (MLXLMCommon's `.toolCall` generations) use this to hand the agent loop
/// text its parser recognizes.
enum ToolCallText {
    static func serialize(name: String, argumentsJSON: String) -> String {
        let safeName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "<tool_call>\n{\"name\": \"\(safeName)\", \"arguments\": \(argumentsJSON)}\n</tool_call>"
    }
}
