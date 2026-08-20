import Foundation

/// Structured tool spec sent to BYOK APIs as native function-calling.
/// The loop still parses the existing text protocol — this bridge converts
/// streamed `tool_calls` / `tool_use` back into that wire format.
struct NativeToolSpec: Sendable, Equatable {
    var name: String
    var description: String
    var schemaText: String

    init(name: String, description: String, schemaText: String) {
        self.name = name
        self.description = description
        self.schemaText = schemaText
    }

    init(tool: any AgentTool) {
        self.init(name: tool.name, description: tool.summary, schemaText: tool.schemaText)
    }
}

/// Engines that can advertise native tools to a remote API.
protocol NativeToolConfigurable: AnyObject {
    func configureNativeTools(_ tools: [NativeToolSpec])
}

enum NativeToolBridge {

    /// OpenAI `tools: [{type:function, function:{name,description,parameters}}]`.
    struct OpenAITool: Encodable, Sendable {
        var type: String = "function"
        var function: Function
        struct Function: Encodable, Sendable {
            var name: String
            var description: String
            var parameters: JSONBox
        }
    }

    /// Anthropic `tools: [{name, description, input_schema}]`.
    struct AnthropicTool: Encodable, Sendable {
        var name: String
        var description: String
        var input_schema: JSONBox
    }

    /// Gemini groups function declarations inside one `tools` entry.
    struct GeminiTool: Codable, Sendable {
        var functionDeclarations: [FunctionDeclaration]

        struct FunctionDeclaration: Codable, Sendable {
            var name: String
            var description: String
            var parameters: JSONBox
        }
    }

    static func openAITools(from specs: [NativeToolSpec]) -> [OpenAITool] {
        specs.map { spec in
            OpenAITool(function: .init(
                name: spec.name,
                description: spec.description,
                parameters: JSONBox.parse(spec.schemaText)))
        }
    }

    static func anthropicTools(from specs: [NativeToolSpec]) -> [AnthropicTool] {
        specs.map { spec in
            AnthropicTool(
                name: spec.name,
                description: spec.description,
                input_schema: JSONBox.parse(spec.schemaText))
        }
    }

    static func geminiTools(from specs: [NativeToolSpec]) -> [GeminiTool] {
        guard !specs.isEmpty else { return [] }
        return [GeminiTool(functionDeclarations: specs.map { spec in
            GeminiTool.FunctionDeclaration(
                name: spec.name,
                description: spec.description,
                parameters: JSONBox.parse(spec.schemaText))
        })]
    }

    /// Fold streamed fragments (by index) into the first complete call and
    /// emit the text fence `ToolParser` already understands.
    static func serializeAccumulated(_ fragments: [Int: (name: String, arguments: String)]) -> String? {
        let ordered = fragments.sorted { $0.key < $1.key }
        guard let first = ordered.first, !first.value.name.isEmpty else { return nil }
        let args = first.value.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = args.isEmpty ? "{}" : args
        return ToolCallText.serialize(name: first.value.name, argumentsJSON: json)
    }

    /// Recursive JSON so we can embed a tool's schemaText as a real object,
    /// not a string, in the provider payload.
    enum JSONBox: Codable, Sendable, Equatable {
        case object([String: JSONBox])
        case array([JSONBox])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        static func parse(_ text: String) -> JSONBox {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data)
            else {
                return .object(["type": .string("object"), "properties": .object([:])])
            }
            return from(any)
        }

        static func from(_ any: Any) -> JSONBox {
            switch any {
            case let dict as [String: Any]:
                .object(dict.mapValues { from($0) })
            case let list as [Any]:
                .array(list.map { from($0) })
            case let text as String:
                .string(text)
            case let number as NSNumber:
                // Bool is bridged as NSNumber — distinguish it.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    .bool(number.boolValue)
                } else {
                    .number(number.doubleValue)
                }
            default:
                .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let object): try container.encode(object)
            case .array(let array): try container.encode(array)
            case .string(let string): try container.encode(string)
            case .number(let number): try container.encode(number)
            case .bool(let flag): try container.encode(flag)
            case .null: try container.encodeNil()
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let object = try? container.decode([String: JSONBox].self) {
                self = .object(object)
            } else if let array = try? container.decode([JSONBox].self) {
                self = .array(array)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value")
            }
        }
    }
}
