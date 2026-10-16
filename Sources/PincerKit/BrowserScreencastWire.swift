import Foundation

/// The screencast socket's messages (openclaw `extensions/browser/src/browser/screencast/wire.ts`).
/// Binary: a big-endian UInt32 header length, a UTF-8 JSON header, then the JPEG bytes.
/// Text: `{type: "ready" | "meta" | "error", …}`. Everything here is untrusted input.
public enum BrowserScreencastWire {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxMessageBytes = 8 * 1024 * 1024

    public struct Header: Sendable, Equatable {
        public var url: String?
        public var cssWidth: Double?
        public var cssHeight: Double?
        public var scrollX: Double?
        public var scrollY: Double?
        public var ts: Double?

        public init(url: String? = nil, cssWidth: Double? = nil, cssHeight: Double? = nil,
                    scrollX: Double? = nil, scrollY: Double? = nil, ts: Double? = nil)
        {
            self.url = url
            self.cssWidth = cssWidth
            self.cssHeight = cssHeight
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.ts = ts
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case truncated
        case headerTooLarge
        case messageTooLarge
        case invalidHeader
    }

    public static func parse(_ data: Data) throws -> (header: Header, jpeg: Data) {
        guard data.count <= self.maxMessageBytes else { throw ParseError.messageTooLarge }
        guard data.count >= 5 else { throw ParseError.truncated }
        let start = data.startIndex
        var length = 0
        for offset in 0..<4 { length = length << 8 | Int(data[start + offset]) }
        guard length > 0 else { throw ParseError.invalidHeader }
        guard length <= self.maxHeaderBytes else { throw ParseError.headerTooLarge }
        // The JPEG must be non-empty, as upstream's client requires.
        guard length < data.count - 4 else { throw ParseError.truncated }
        let headerData = data[(start + 4)..<(start + 4 + length)]
        guard let object = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            throw ParseError.invalidHeader
        }
        func number(_ key: String) -> Double? {
            guard let value = (object[key] as? NSNumber), !(object[key] is Bool) else { return nil }
            let double = value.doubleValue
            return double.isFinite ? double : nil
        }
        let header = Header(
            url: object["url"] as? String, cssWidth: number("cssWidth"), cssHeight: number("cssHeight"),
            scrollX: number("scrollX"), scrollY: number("scrollY"), ts: number("ts"))
        return (header, Data(data[(start + 4 + length)...]))
    }

    public enum Control: Equatable, Sendable {
        case ready(targetId: String, url: String?, title: String?)
        case meta(url: String?, title: String?)
        case error(String?)
    }

    public static func parseControl(_ text: String) -> Control? {
        guard text.utf8.count <= self.maxHeaderBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            guard let targetId = object["targetId"] as? String else { return nil }
            return .ready(targetId: targetId, url: object["url"] as? String, title: object["title"] as? String)
        case "meta":
            return .meta(url: object["url"] as? String, title: object["title"] as? String)
        case "error":
            return .error((object["message"] as? String) ?? (object["error"] as? String))
        default:
            return nil
        }
    }
}
