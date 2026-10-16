import Foundation

/// Where the Gateway should route a `browser.request`: a profile, and the host or a node.
/// Upstream puts `target` and `node` at the top of the params and `profile` in `query`.
public struct BrowserRoute: Hashable, Sendable, Codable {
    public var profile: String?
    public var target: String?
    public var node: String?

    public init(profile: String? = nil, target: String? = nil, node: String? = nil) {
        self.profile = profile
        self.target = target
        self.node = node
    }
}

/// The page a `browser` tool call touched: `details.browserTab` of its result
/// (openclaw `extensions/browser/src/browser-tool.ts`).
public struct BrowserTabRef: Hashable, Sendable, Codable {
    public static let maxURLLength = 2048
    public static let maxTitleLength = 512

    public let targetId: String
    public let profile: String?
    /// `host` or `node`.
    public let target: String?
    public let node: String?
    /// http(s) only; nil for anything else.
    public let url: URL?
    public let title: String?

    public init(targetId: String, profile: String? = nil, target: String? = nil, node: String? = nil,
                url: URL? = nil, title: String? = nil)
    {
        self.targetId = targetId
        self.profile = profile
        self.target = target
        self.node = node
        self.url = url.flatMap(Self.webURL)
        self.title = title
    }

    public var host: String? { self.url?.host(percentEncoded: false) }

    public var route: BrowserRoute { BrowserRoute(profile: self.profile, target: self.target, node: self.node) }

    public static func parse(_ details: JSONValue?) -> BrowserTabRef? {
        guard let tab = details?["browserTab"], tab.object != nil,
              let targetId = tab["targetId"]?.text, targetId.count <= 128
        else { return nil }
        let target = tab["target"]?.text.flatMap { ["host", "node"].contains($0) ? $0 : nil }
        return BrowserTabRef(
            targetId: targetId, profile: tab["profile"]?.text.map { String($0.prefix(128)) }, target: target,
            node: target == "node" ? tab["node"]?.text.map { String($0.prefix(256)) } : nil,
            url: tab["url"]?.string.flatMap { Self.webURL($0) },
            title: tab["title"]?.text.map { String($0.prefix(Self.maxTitleLength)) })
    }

    static func webURL(_ text: String) -> URL? {
        guard text.count <= Self.maxURLLength else { return nil }
        return URL(string: text).flatMap(Self.webURL)
    }

    static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// One page in the agent's browser, from `GET /tabs`.
public struct BrowserPageTab: Hashable, Sendable, Identifiable {
    public let targetId: String
    public var title: String
    public var url: URL?
    public var favicon: URL?
    /// `navigation_blocked` or `navigation_check_failed` when the Gateway withheld the URL.
    public var urlUnavailableReason: String?
    public var route: BrowserRoute

    public var id: String { self.targetId }

    public init(targetId: String, title: String = "", url: URL? = nil, favicon: URL? = nil,
                urlUnavailableReason: String? = nil, route: BrowserRoute = BrowserRoute())
    {
        self.targetId = targetId
        self.title = title
        self.url = url
        self.favicon = favicon
        self.urlUnavailableReason = urlUnavailableReason
        self.route = route
    }

    init(_ ref: BrowserTabRef) {
        self.init(targetId: ref.targetId, title: ref.title ?? "", url: ref.url, route: ref.route)
    }

    /// The `/tabs` reply as upstream's `listBrowserTabs` reads it: `running` is strictly `true`, rows without a `targetId` are dropped.
    static func parseList(_ reply: JSONValue, route: BrowserRoute) -> (running: Bool, tabs: [BrowserPageTab]) {
        let rows = reply["tabs"]?.array ?? []
        let tabs: [BrowserPageTab] = rows.compactMap { row in
            guard let targetId = row["targetId"]?.string, !targetId.isEmpty else { return nil }
            let reason = row["urlUnavailableReason"]?.string
            return BrowserPageTab(
                targetId: targetId, title: row["title"]?.string ?? "",
                url: row["url"]?.string.flatMap { BrowserTabRef.webURL($0) },
                favicon: row["favicon"]?.string.flatMap { BrowserTabRef.webURL($0) },
                urlUnavailableReason: reason == "navigation_blocked" || reason == "navigation_check_failed" ? reason : nil,
                route: route)
        }
        return (reply["running"]?.bool == true, tabs)
    }
}
