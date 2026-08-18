import Foundation

/// A small self-contained JSON value tree used to carry tool arguments around
/// without depending on `Any` hashing or a third-party codable helper.
public enum LFJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LFJSONValue])
    case object([String: LFJSONValue])

    public static func decode(_ data: Data) throws -> LFJSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return convert(any)
    }

    public static func decode(_ text: String) throws -> LFJSONValue {
        try decode(Data(text.utf8))
    }

    private static func convert(_ any: Any) -> LFJSONValue {
        switch any {
        case is NSNull: .null
        case let number as NSNumber:
            // NSNumber bridges `1 as Bool == true`; distinguish real JSON booleans
            // (CFBoolean) from numbers before deciding the case.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                .bool(number.boolValue)
            } else {
                .number(number.doubleValue)
            }
        case let string as String: .string(string)
        case let array as [Any]: .array(array.map(convert))
        case let object as [String: Any]: .object(object.mapValues(convert))
        default: .null
        }
    }

    public var objectValue: [String: LFJSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [LFJSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Pretty-printed JSON for logging and prompts.
    public func encoded(prettyPrinted: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let any = revert()
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private func revert() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map { $0.revert() }
        case .object(let dict): return dict.mapValues { $0.revert() }
        }
    }
}
