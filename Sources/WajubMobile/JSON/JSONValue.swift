import Foundation

/// A JSON value, read leniently.
///
/// Every wire model of the SDK is built from a `JSONValue` rather than with
/// `Codable`, so that the parsing rules of the contract hold everywhere: unknown
/// keys are ignored, every key may be missing, a number may arrive as an
/// integer, a decimal or a numeric string, a boolean as `true`/`false`, `0`/`1`
/// or `"true"`/`"false"`, and keys containing a dot (`"name.fr"`) are literal
/// keys.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses UTF-8 JSON.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a JSON string.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// The value under `key` when this is an object. The key is literal: `"name.fr"` is one key.
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A string, or a number written as one (ids sometimes arrive as numbers).
    public var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return JSONValue.format(value)
        default: return nil
        }
    }

    /// A non-empty string.
    public var nonEmptyString: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }

    /// A finite number from a number or a numeric string (`25000`, `25000.0`, `"25000"`, `"25000.00"`).
    public var double: Double? {
        switch self {
        case .number(let value):
            return value.isFinite ? value : nil
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.allSatisfy({ "0123456789.-+eE".contains($0) }),
                  let value = Double(trimmed), value.isFinite else { return nil }
            return value
        default:
            return nil
        }
    }

    /// An integer from any numeric encoding; decimals are truncated toward zero.
    public var int: Int? {
        guard let value = double, value.magnitude < 9.0e15 else { return nil }
        return Int(value)
    }

    /// A boolean from `true`/`false`, `0`/`1` or `"true"`/`"false"` (also `"1"`/`"0"`).
    public var bool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            if value == 1 { return true }
            if value == 0 { return false }
            return nil
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A list of strings, skipping entries that are not strings.
    public var strings: [String] {
        (array ?? []).compactMap { $0.string }
    }

    /// Compact JSON with sorted keys, so the same value always gives the same bytes.
    public func serialized() -> Data {
        var output = ""
        JSONValue.write(self, into: &output)
        return Data(output.utf8)
    }

    /// `serialized()` as a string.
    public var jsonString: String {
        String(decoding: serialized(), as: UTF8.self)
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func write(_ value: JSONValue, into output: inout String) {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let number):
            output += number.isFinite ? format(number) : "null"
        case .string(let text):
            writeString(text, into: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                write(item, into: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                writeString(key, into: &output)
                output += ":"
                write(members[key] ?? .null, into: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// Builds request bodies: `nil` values are left out.
struct JSONObjectBuilder {
    private(set) var members: [String: JSONValue] = [:]

    mutating func set(_ key: String, _ value: String?) {
        if let value { members[key] = .string(value) }
    }

    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { members[key] = value }
    }

    mutating func set(_ key: String, _ value: Bool?) {
        if let value { members[key] = .bool(value) }
    }

    var value: JSONValue { .object(members) }
}
