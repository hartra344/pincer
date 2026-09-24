import Foundation

/// Loosely-typed JSON used for Gateway payloads. The Gateway schema evolves quickly,
/// so the client reads the fields it understands and ignores the rest.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Non-empty trimmed string, or nil.
    public var text: String? {
        guard let value = self.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    public var double: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    public var int: Int? {
        guard let value = self.double, value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    public var int64: Int64? {
        guard let value = self.double, value.isFinite, value.rounded() == value else { return nil }
        return Int64(exactly: value)
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case let .object(dict) = self { return dict }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public func contains(_ key: String) -> Bool {
        self.object?[key] != nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if value.rounded() == value, let exact = Int64(exactly: value) {
                try container.encode(exact)
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension JSONValue {
    init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: [String]) { self = .array(value.map(JSONValue.string)) }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
