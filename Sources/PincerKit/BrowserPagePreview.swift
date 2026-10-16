import Foundation

/// A page card for a successful `browser` tool call, built from `details.browserTab` alone
/// (upstream `extensions/browser/src/browser-tool.ts`). Pixels never arrive in the tool result.
public struct BrowserPagePreview: Hashable, Sendable {
    public let toolCallId: String
    public let url: URL
    public let title: String?
    public let tabKey: String

    public var host: String { self.url.host(percentEncoded: false) ?? self.url.absoluteString }
    /// Host with its port when the URL has one (`example.com:8443`).
    var hostAndPort: String { self.url.port.map { "\(self.host):\($0)" } ?? self.host }
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

    /// Footer lines: `browserTab.title`, else the link preview's title, else the host; the subtitle is the
    /// URL, or just path + query when line 1 already is the host (unless the path is "/").
    public func footer(linkTitle: String?) -> (title: String, subtitle: String) {
        if let title { return (title, self.displayURL) }
        if let linkTitle = linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !linkTitle.isEmpty {
            return (linkTitle, self.displayURL)
        }
        let path = self.url.path(percentEncoded: false)
        guard path != "/" else { return (self.hostAndPort, self.displayURL) }
        var rest = path
        if let query = self.url.query(percentEncoded: false), !query.isEmpty { rest += "?\(query)" }
        return (self.hostAndPort, rest)
    }

    /// The latest successful result per tab, ordered by when that result came, at most `limit` (the most recent tabs).
    public static func latestPerTab(_ tools: [ToolActivity], limit: Int = 3) -> [BrowserPagePreview] {
        var latest: [String: (index: Int, page: BrowserPagePreview)] = [:]
        for (index, tool) in tools.enumerated() {
            guard let page = tool.browserPage else { continue }
            latest[page.tabKey] = (index, page)
        }
        return latest.values.sorted { $0.index < $1.index }.suffix(max(limit, 0)).map(\.page)
    }

    /// For each tab, the id of the latest assistant turn that shows a card for it. The screenshot hook
    /// (`BrowserPagePreviews.setScreenshot`) applies only to that turn's card; older turns keep their og:image.
    public static func latestTurnIds(_ entries: [TranscriptEntry]) -> [String: String] {
        var turns: [String: String] = [:]
        for entry in entries {
            guard case let .assistant(turn) = entry else { continue }
            for page in latestPerTab(turn.tools) { turns[page.tabKey] = turn.id }
        }
        return turns
    }
}
