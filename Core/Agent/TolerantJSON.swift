import Foundation

/// Normalizes nearly-JSON emitted by small local models into strict JSON.
/// Handles the classic failure modes: single-quoted strings, trailing commas,
/// `//` and `/* */` comments, and smart quotes.
enum TolerantJSON {

    /// Returns strict-JSON data, or nil when the input is not recoverable.
    static func data(from raw: String) -> Data? {
        guard let normalized = normalize(raw) else { return nil }
        return normalized.data(using: .utf8)
    }

    /// Returns the parsed value tree, or nil when the input is not recoverable.
    static func value(from raw: String) -> LFJSONValue? {
        guard let data = data(from: raw) else { return nil }
        return try? LFJSONValue.decode(data)
    }

    static func normalize(_ raw: String) -> String? {
        var output = ""

        enum State {
            case outside
            case inDoubleQuoted
            case inSingleQuoted
            case inLineComment
            case inBlockComment
        }
        var state = State.outside
        let scalars = Array(raw.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let current = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil

            switch state {
            case .outside:
                switch current {
                case "/":
                    if next == "/" {
                        state = .inLineComment
                        index += 2
                        continue
                    } else if next == "*" {
                        state = .inBlockComment
                        index += 2
                        continue
                    } else {
                        output.append("/")
                        index += 1
                    }
                case "\"":
                    state = .inDoubleQuoted
                    output.append("\"")
                    index += 1
                case "'":
                    // Single-quoted string → emit as double-quoted.
                    state = .inSingleQuoted
                    output.append("\"")
                    index += 1
                case "“", "”":
                    state = .inDoubleQuoted
                    output.append("\"")
                    index += 1
                case ",":
                    // Trailing comma detection: skip commas whose next
                    // non-whitespace is } or ].
                    if let closing = nextNonWhitespace(after: index, in: scalars),
                       closing == "}" || closing == "]"
                    {
                        index += 1
                    } else {
                        output.append(",")
                        index += 1
                    }
                default:
                    output.append(String(current))
                    index += 1
                }

            case .inDoubleQuoted:
                switch current {
                case "\\":
                    if let next {
                        output.append("\\")
                        output.append(String(next))
                        index += 2
                    } else {
                        index += 1
                    }
                case "\"":
                    state = .outside
                    output.append("\"")
                    index += 1
                case "\n":
                    // Raw newline inside a string is invalid JSON — escape it.
                    output.append("\\n")
                    index += 1
                default:
                    output.append(String(current))
                    index += 1
                }

            case .inSingleQuoted:
                switch current {
                case "\\":
                    if let next {
                        output.append("\\")
                        output.append(String(next))
                        index += 2
                    } else {
                        index += 1
                    }
                case "'":
                    state = .outside
                    output.append("\"")
                    index += 1
                case "\"":
                    // Inner double quote must be escaped in the converted string.
                    output.append("\\\"")
                    index += 1
                case "\n":
                    output.append("\\n")
                    index += 1
                default:
                    output.append(String(current))
                    index += 1
                }

            case .inLineComment:
                if current == "\n" {
                    state = .outside
                    output.append("\n")
                }
                index += 1

            case .inBlockComment:
                if current == "*", next == "/" {
                    state = .outside
                    index += 2
                } else {
                    index += 1
                }
            }
        }

        guard state == .outside else { return nil }
        let text = output
        // Final validation: only return when it is real JSON.
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }
        return text
    }

    private static func nextNonWhitespace(after index: Int, in scalars: [Unicode.Scalar]) -> Unicode.Scalar? {
        var cursor = index + 1
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if !scalar.properties.isWhitespace { return scalar }
            cursor += 1
        }
        return nil
    }
}
