import Foundation

/// A page card for a successful `browser` tool call, built from `details.browserTab` alone
/// (upstream `extensions/browser/src/browser-tool.ts`). Pixels never arrive in the tool result.
public struct BrowserPagePreview: Hashable, Sendable {
    public let toolCallId: String
    public let url: URL
    public let title: String?
    public let tabKey: String

    public var host: String { self.url.host(percentEncoded: false) ?? self.url.absoluteString }
    public var displayTitle: String { self.title ?? self.host }
    public var displayURL: String {
        var text = self.host
        if let port = self.url.port { text += ":\(port)" }
        let path = self.url.path(percentEncoded: false)
        if path != "/" { text += path }
        if let query = self.url.query(percentEncoded: false), !query.isEmpty { text += "?\(query)" }
        return text
    }

    /// Keeps `browserTab`'s string scalars (url ≤ 2048, title ≤ 512) for `ToolActivity.fileEditDetails`.
    static func trimmedTab(_ details: [String: JSONValue]) -> JSONValue? {
        guard let tab = details["browserTab"]?.object else { return nil }
        var kept: [String: JSONValue] = [:]
        for key in ["targetId", "profile", "target", "node"] {
            if let value = tab[key]?.string { kept[key] = .string(value) }
        }
        if let url = tab["url"]?.string, url.utf8.count <= 2048 { kept["url"] = .string(url) }
        if let title = tab["title"]?.string, title.utf8.count <= 512 { kept["title"] = .string(title) }
        return kept.isEmpty ? nil : .object(kept)
    }

    public static func parse(toolName: String, details: JSONValue?, isError: Bool, toolCallId: String) -> BrowserPagePreview? {
        guard toolName == "browser", !isError, let tab = details?["browserTab"]?.object,
              let targetId = tab["targetId"]?.string, !targetId.isEmpty,
              let profile = tab["profile"]?.string, !profile.isEmpty,
              let target = tab["target"]?.string,
              let urlText = tab["url"]?.string, urlText.utf8.count <= 2048,
              let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host(percentEncoded: false)?.isEmpty == false
        else { return nil }
        let key: String
        switch target {
        case "host": key = "host|\(profile)|\(targetId)"
        case "node":
            guard let node = tab["node"]?.string, !node.isEmpty else { return nil }
            key = "node|\(node)|\(profile)|\(targetId)"
        default: return nil
        }
        let title = tab["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserPagePreview(toolCallId: toolCallId, url: url, title: title?.isEmpty == false ? title : nil, tabKey: key)
    }

    /// The latest successful result per tab, keyed by tool call id.
    public static func latestPerTab(_ tools: [ToolActivity]) -> [String: BrowserPagePreview] {
        var latest: [String: BrowserPagePreview] = [:]
        for tool in tools {
            guard let page = tool.browserPage else { continue }
            latest[page.tabKey] = page
        }
        return Dictionary(latest.values.map { ($0.toolCallId, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
