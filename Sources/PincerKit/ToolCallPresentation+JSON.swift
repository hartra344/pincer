import Foundation

/// JSON that remembers object key order, which `JSONSerialization` and `JSONValue` don't.
enum OrderedJSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        lhs.jsonValue == rhs.jsonValue
    }

    static func parse(_ text: String) -> OrderedJSON? {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? value : nil
    }

    var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .number(raw): .number(Double(raw) ?? 0)
        case let .string(value): .string(value)
        case let .array(items): .array(items.map(\.jsonValue))
        case let .object(pairs):
            .object(Dictionary(pairs.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { _, last in last }))
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    func member(_ key: String) -> OrderedJSON? {
        if case let .object(pairs) = self { return pairs.last { $0.key == key }?.value }
        return nil
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    var compact: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .number(raw): raw
        case let .string(value): Self.escape(value)
        case let .array(items): "[" + items.map(\.compact).joined(separator: ",") + "]"
        case let .object(pairs):
            "{" + pairs.map { Self.escape($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
        }
    }

    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let end = String(repeating: "  ", count: indent)
        switch self {
        case let .array(items) where !items.isEmpty:
            return "[\n" + items.map { pad + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case let .object(pairs) where !pairs.isEmpty:
            return "{\n"
                + pairs.map { pad + Self.escape($0.key) + ": " + $0.value.pretty(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + end + "}"
        default:
            return self.compact
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> OrderedJSON? {
            guard depth < 64, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(OrderedJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) -> OrderedJSON? {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { return nil }
            index += w.count
            return value
        }

        mutating func number() -> OrderedJSON? {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let raw = String(bytes: bytes[start..<index], encoding: .utf8),
                  Double(raw) != nil else { return nil }
            return .number(raw)
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count,
                  let s = String(bytes: bytes[index..<index + 4], encoding: .utf8),
                  let v = UInt32(s, radix: 16) else { return nil }
            index += 4
            return v
        }

        mutating func string() -> String? {
            guard bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var out: [UInt8] = []
            var pendingHigh: UInt32?
            func append(_ scalar: UInt32) {
                if let s = Unicode.Scalar(scalar) { out.append(contentsOf: Array(String(Character(s)).utf8)) }
            }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") {
                    return String(decoding: out, as: UTF8.self)
                }
                guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
                guard index < bytes.count else { return nil }
                let esc = bytes[index]
                index += 1
                switch esc {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "/"), UInt8(ascii: "\\"), UInt8(ascii: "\""): out.append(esc)
                case UInt8(ascii: "u"):
                    guard let code = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else { append(0xFFFD); continue }
                        index += 2
                        pendingHigh = code
                        guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                        append(0x10000 + ((pendingHigh! - 0xD800) << 10) + (low - 0xDC00))
                    } else {
                        append(code)
                    }
                default: return nil
                }
            }
            return nil
        }

        mutating func array(depth: Int) -> OrderedJSON? {
            index += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object(depth: Int) -> OrderedJSON? {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard index < bytes.count, let key = string() else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                pairs.append((key, item))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                return nil
            }
        }
    }
}

public enum ToolOutputText {
    /// Text of a tool result: the envelope's text parts when it is one, pretty JSON for other
    /// JSON, the string itself otherwise.
    public static func unwrap(_ result: String) -> (text: String, imageCount: Int, details: JSONValue?) {
        let trimmed = result.drop { $0.isWhitespace }
        guard let first = trimmed.first, first == "{" || first == "[",
              let parsed = OrderedJSON.parse(result)
        else {
            return (unescapeIfFlat(result), 0, nil)
        }
        var items: [OrderedJSON]?
        var details: OrderedJSON?
        switch parsed {
        case .object:
            if case let .array(content)? = parsed.member("content") {
                items = content
                details = parsed.member("details")
            }
        case let .array(content):
            if !content.isEmpty, content.allSatisfy({ $0.member("type")?.stringValue != nil }) {
                items = content
            }
        default:
            break
        }
        guard let items else { return (unescapeIfFlat(parsed.pretty()), 0, nil) }
        var texts: [String] = []
        var images = 0
        for item in items {
            switch item.member("type")?.stringValue {
            case "text": if let text = item.member("text")?.stringValue { texts.append(text) }
            case "image": images += 1
            default: break
            }
        }
        var text = texts.joined(separator: "\n")
        if text.isEmpty, let aggregated = details?.member("aggregated")?.stringValue { text = aggregated }
        return (unescapeIfFlat(text), images, details?.jsonValue)
    }

    static func unescapeIfFlat(_ text: String) -> String {
        guard !text.contains("\n"), text.contains("\\n") else { return text }
        return text.replacingOccurrences(of: "\\r\\n", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Removes ANSI CSI and OSC escape sequences.
    public static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// Keeps the start and end of `s` when it is longer than `max`, replacing the middle with `…`.
    public static func middleTruncated(_ s: String, max: Int) -> String {
        guard max > 1, s.count > max else { return s }
        let head = (max - 1 + 1) / 2
        let tail = max - 1 - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}
