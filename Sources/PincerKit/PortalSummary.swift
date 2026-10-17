import Foundation

/// One entry of `portal.list` / `portal.changed` (openclaw `PortalSummary`). Parsed tolerantly: unknown
/// fields are ignored, optional ones may be missing, and an entry without `id`, `title` or a usable
/// `publicUrl` is dropped.
public struct PortalSummary: Hashable, Identifiable, Sendable {
    public struct Exposure: Hashable, Sendable {
        /// `loopback-only` or `non-loopback`.
        public let kind: String
        public let browserReachability: String?

        public var isLoopbackOnly: Bool { self.kind == "loopback-only" }
    }

    /// Scheme the demo's bundled portal uses; the UI serves it from memory.
    public static let demoScheme = "demo-portal"

    public let id: String
    public let title: String
    public let port: Int
    public let listenPort: Int
    /// The portal's own origin and path. Never contains the access token.
    public let publicURL: URL
    public let createdAtMs: Double
    /// `publicUrl` plus `?openclaw_portal=<token>`. Only operator.write or admin callers get it.
    /// Carries a secret: never log it, show it or put it in an error.
    public let loadURL: URL?
    public let path: String?
    public let details: String?
    public let exposure: Exposure?

    /// What the UI shows: the public URL without any token.
    public var displayURL: URL { PortalOriginPolicy.strippedForDisplay(self.publicURL) }

    /// The connection can't open this portal (the Gateway redacted the access link).
    public var isRedacted: Bool { self.loadURL == nil }

    public init(id: String, title: String, port: Int = 0, listenPort: Int = 0, publicURL: URL, createdAtMs: Double = 0,
                loadURL: URL? = nil, path: String? = nil, details: String? = nil, exposure: Exposure? = nil) {
        self.id = id
        self.title = title
        self.port = port
        self.listenPort = listenPort
        self.publicURL = publicURL
        self.createdAtMs = createdAtMs
        self.loadURL = loadURL
        self.path = path
        self.details = details
        self.exposure = exposure
    }

    /// `allowsDemoScheme` admits `demo-portal://` URLs; only the demo gateway's store sets it.
    public static func parse(_ value: JSONValue, allowsDemoScheme: Bool = false) -> PortalSummary? {
        guard let id = value["id"]?.string, !id.isEmpty, id.count <= 256,
              let title = value["title"]?.string, !title.isEmpty,
              let publicURL = Self.allowedURL(value["publicUrl"]?.string, allowsDemoScheme: allowsDemoScheme) else { return nil }
        var load = Self.allowedURL(value["url"]?.string, allowsDemoScheme: allowsDemoScheme)
        // A link to a different origin than the portal's own is never loaded.
        if let candidate = load, !PortalOriginPolicy.sameOrigin(candidate, publicURL) { load = nil }
        let exposure = value["exposure"]?["kind"]?.string.map {
            Exposure(kind: $0, browserReachability: value["exposure"]?["browserReachability"]?.string)
        }
        let path = value["path"]?.string
        return PortalSummary(
            id: id, title: String(title.prefix(200)),
            port: value["port"]?.int ?? 0, listenPort: value["listenPort"]?.int ?? 0,
            publicURL: publicURL, createdAtMs: value["createdAtMs"]?.double ?? 0, loadURL: load,
            path: path?.hasPrefix("/") == true ? path : nil,
            details: value["description"]?.string.map { String($0.prefix(1000)) },
            exposure: exposure)
    }

    /// Parses `{portals: [...]}`; nil when the reply has no `portals` array.
    public static func parseList(_ reply: JSONValue, allowsDemoScheme: Bool = false) -> [PortalSummary]? {
        guard let array = reply["portals"]?.array else { return nil }
        var seen = Set<String>()
        return array.compactMap { Self.parse($0, allowsDemoScheme: allowsDemoScheme) }.filter { seen.insert($0.id).inserted }
    }

    private static func allowedURL(_ string: String?, allowsDemoScheme: Bool) -> URL? {
        guard let string, string.count <= 4096, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              url.host?.isEmpty == false else { return nil }
        guard scheme == "http" || scheme == "https" || (allowsDemoScheme && scheme == Self.demoScheme) else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// Which pages a portal's web view may show: only the portal's own origin.
public enum PortalOriginPolicy {
    public static let tokenQueryItem = "openclaw_portal"

    /// Scheme, host and port (default ports normalised) of `url` in a comparable form; nil for an
    /// unusable URL or one carrying userinfo. The host is `URL.host` (IDNA/punycode canonical form, so a
    /// homograph is a different origin), lowercased. A trailing dot is kept (so it doesn't match) and
    /// there is no loopback alias equivalence (`localhost`, `127.0.0.1` and `[::1]` are all different).
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == PortalSummary.demoScheme,
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? Self.defaultPort(scheme)
        return "\(scheme)://\(host):\(port.map(String.init) ?? "")"
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let first = self.origin(of: a), let second = self.origin(of: b) else { return false }
        return first == second
    }

    /// Whether the portal's web view may navigate to `url`. `about:blank` and `about:srcdoc` are fine for
    /// subframes only (srcdoc inherits its parent's origin).
    public static func allows(_ url: URL, portal: PortalSummary, isMainFrame: Bool = true) -> Bool {
        if ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased()) { return !isMainFrame }
        return self.sameOrigin(url, portal.publicURL)
    }

    /// `url` without the `openclaw_portal` access token, for showing and for "Open in Browser" warnings.
    public static func strippedForDisplay(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        guard let items = parts.queryItems, items.contains(where: { $0.name == Self.tokenQueryItem }) else { return url }
        let kept = items.filter { $0.name != Self.tokenQueryItem }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    /// What may be handed to the system browser for a link the user tapped: http or https only
    /// (never `pincer://`, `file:`, `javascript:`, `mailto:` and so on), without userinfo, with the
    /// `openclaw_portal` access token removed. Nil means: don't open it.
    public static func externalURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return self.strippedForDisplay(url)
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}

/// The portals a chat's agent opened itself (successful `portal` tool calls with `action: open`).
public struct PortalRefs: Hashable, Sendable {
    public var ids: Set<String>
    public var publicURLs: Set<String>

    public static let empty = PortalRefs()
    public var isEmpty: Bool { self.ids.isEmpty && self.publicURLs.isEmpty }

    public init(ids: Set<String> = [], publicURLs: Set<String> = []) {
        self.ids = ids
        self.publicURLs = publicURLs
    }

    public init<S: Sequence>(tools: S) where S.Element == ToolActivity {
        self.init()
        for tool in tools { self.insert(tool.openedPortal) }
    }

    mutating func insert(_ open: PortalToolOpen?) {
        guard let open else { return }
        if let id = open.id { self.ids.insert(id) }
        if let url = open.publicURL { self.publicURLs.insert(Self.normalized(url)) }
    }

    func contains(_ portal: PortalSummary) -> Bool {
        self.ids.contains(portal.id) || self.publicURLs.contains(Self.normalized(portal.publicURL.absoluteString))
    }

    static func normalized(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}

/// Which portals one chat shows: those its session owns plus those its agent opened in the transcript.
public struct PortalScope: Hashable, Sendable {
    public var sessionKey: String
    public var agentId: String?
    public var opened: PortalRefs

    public init(sessionKey: String, agentId: String? = nil, opened: PortalRefs = .empty) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.opened = opened
    }
}
