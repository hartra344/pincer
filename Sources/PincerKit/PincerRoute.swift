import Foundation

/// Where a `pincer://` link, a Handoff activity, a notification, or a shortcut takes the app.
/// Routes only ever navigate: they never send, approve, or fill in anything.
///
/// URL form: `pincer://open?gateway=<UUID|demo>&session=<key>[&message=<id>]`. The demo
/// gateway's id differs per install, so links to it say `demo` instead.
public struct PincerRoute: Hashable, Sendable {
    public enum Gateway: Hashable, Sendable {
        case id(UUID)
        /// The built-in demo, whatever its id on this device.
        case demo
    }

    public var gateway: Gateway
    /// The chat to open; nil opens the gateway on its current chat.
    public var sessionKey: String?
    /// A message (`TranscriptEntry`/message id) to scroll to once the chat is open.
    public var messageId: String?
    /// The gateway's address, for finding it on another device where its id differs. Always
    /// `normalizedGatewayURL` form: no credentials, query, or fragment.
    public var gatewayURL: String?

    public init(gateway: Gateway, sessionKey: String? = nil, messageId: String? = nil, gatewayURL: String? = nil) {
        self.gateway = gateway
        self.sessionKey = sessionKey.flatMap { $0.isEmpty ? nil : $0 }
        self.messageId = messageId.flatMap { $0.isEmpty ? nil : $0 }
        self.gatewayURL = gateway == .demo ? nil : gatewayURL.flatMap(Self.normalizedGatewayURL)
    }

    /// A route to a chat; `isDemo` writes the gateway as `demo` so the link works on any device.
    public init(target: Notifier.Target, isDemo: Bool = false, messageId: String? = nil, gatewayURL: String? = nil) {
        self.init(gateway: isDemo ? .demo : .id(target.gatewayId), sessionKey: target.sessionKey,
                  messageId: messageId, gatewayURL: gatewayURL)
    }

    /// `scheme://host[:port][/path]` of a `ws`/`wss`/`http`/`https` gateway address: scheme and
    /// host lowercased, default ports and a trailing slash dropped, and any `user:password@`,
    /// query, or fragment removed. Nil for anything else.
    public static func normalizedGatewayURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.percentEncodedHost?.lowercased(), !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.percentEncodedHost = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if let port = components.port, port == (["ws", "http"].contains(scheme) ? 80 : 443) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    public static let scheme = "pincer"
    public static let host = "open"
    /// `NSUserActivity.activityType` for Handoff of a visible chat. Listed in `NSUserActivityTypes`.
    public static let activityType = "chat.pincer.chat"
    static let demoToken = "demo"

    /// Query item names in the URL, and keys of `userInfo`.
    public enum Key {
        public static let gateway = "gateway"
        public static let session = "session"
        public static let message = "message"
        public static let url = "url"
    }

    /// Fixed wording for what a route couldn't do. Never includes ids from the link.
    public enum Notice {
        public static let unknownGateway = "That link points to a Gateway that isn’t set up on this device."
        public static let unknownSession = "That chat isn’t available on this Gateway anymore."
        public static let unknownMessage = "Couldn’t find that message."
        public static let invalidLink = "Pincer couldn’t open that link."
        public static let linkCopied = "Link copied"
    }

    // MARK: App Intents ids

    /// A chat's App Intents id (`<gatewayUUID>/<sessionKey>`, see `IntentID`) as a route.
    public init?(intentId: String) {
        guard let (gatewayId, key) = IntentID.parse(intentId) else { return nil }
        self.init(gateway: .id(gatewayId), sessionKey: key)
    }

    /// The App Intents id of the chat this routes to; nil for gateway-only or demo routes.
    public var intentId: String? {
        guard case let .id(id) = self.gateway, let key = self.sessionKey else { return nil }
        return IntentID.scoped(id, key)
    }

    // MARK: URL

    /// Parses a `pincer://open?...` URL. Nil for any other scheme, host, or a missing/bad gateway.
    public static func parse(_ url: URL) -> PincerRoute? {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `pincer://open?…` puts "open" in the host; `pincer:open?…` in the path.
        let host = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host.lowercased() == Self.host else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            if let value = item.value { values[item.name] = value }
        }
        return Self(values: values)
    }

    public init?(url: URL) {
        guard let route = Self.parse(url) else { return nil }
        self = route
    }

    /// `pincer://open?gateway=…&session=…[&message=…]`, every value percent-encoded.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        // `URLQueryItem` leaves `+ & = / : ?` alone; encode strictly so any key round-trips.
        let encoded = self.fields.map { "\($0.name)=\(Self.encode($0.value))" }
        components.percentEncodedQuery = encoded.joined(separator: "&")
        return components.url!
    }

    public static func url(for route: PincerRoute) -> URL { route.url }

    // MARK: NSUserActivity

    /// For `NSUserActivity.userInfo`: plain strings only, so it survives Handoff.
    public var userInfo: [String: String] {
        Dictionary(uniqueKeysWithValues: self.fields.map { ($0.name, $0.value) })
    }

    /// The Handoff payload: gateway, session, and address only. Handoff moves the chat, never a
    /// position in it, so `message` is always left out.
    public var handoffUserInfo: [String: String] {
        var route = self
        route.messageId = nil
        return route.userInfo
    }

    /// A route received by Handoff, `message` dropped whatever the sender put in.
    public init?(handoffUserInfo userInfo: [AnyHashable: Any]?) {
        self.init(userInfo: userInfo)
        self.messageId = nil
    }

    /// Decodes `userInfo` written by `userInfo`. Nil when the gateway is missing or malformed.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        var values: [String: String] = [:]
        for key in [Key.gateway, Key.session, Key.message, Key.url] {
            if let value = userInfo[key] as? String { values[key] = value }
        }
        self.init(values: values)
    }

    // MARK: Resolving

    /// What applying a route does, given the saved gateways.
    public enum Resolution: Hashable, Sendable {
        /// Open this chat, then scroll to `messageId` if given.
        case openChat(Notifier.Target, messageId: String?)
        /// Open the gateway on whatever chat it last showed.
        case openGateway(UUID)
        /// A demo link and no demo yet: add the demo, then open the route there.
        case openDemo(sessionKey: String?, messageId: String?)
        /// No saved gateway matches the link.
        case unknownGateway
        /// The gateway exists, but its session list doesn't have this chat. Opens the gateway.
        case unknownSession(gatewayId: UUID, sessionKey: String)
    }

    /// A saved gateway as the resolver sees it.
    public struct Candidate: Hashable, Sendable {
        public let id: UUID
        public let isDemo: Bool
        /// Keys of its listed sessions; nil while they haven't been listed yet (any key is trusted).
        public let sessionKeys: Set<String>?
        /// Its address in `normalizedGatewayURL` form, matched when the id doesn't.
        public let url: String?

        public init(id: UUID, isDemo: Bool, sessionKeys: Set<String>?, url: String? = nil) {
            self.id = id
            self.isDemo = isDemo
            self.sessionKeys = sessionKeys
            self.url = url.flatMap(PincerRoute.normalizedGatewayURL)
        }
    }

    /// Pure resolution against `candidates`. `resolveKey` maps aliases (e.g. `agent:x:main`) to
    /// a gateway's real key; identity by default. `verifySession: false` trusts the session key
    /// (for routes Pincer made itself, e.g. a notification for a chat not listed yet); links and
    /// Handoff from outside verify it. Among gateways sharing an address, `preferring` wins.
    public func resolve(in candidates: [Candidate], verifySession: Bool = true, preferring: UUID? = nil,
                        resolveKey: (UUID, String) -> String = { $1 }) -> Resolution {
        let match: Candidate? = switch self.gateway {
        case let .id(id):
            // Ids are per device; on another one the same gateway is found by its address.
            candidates.first { $0.id == id } ?? self.gatewayURL.flatMap { url in
                let matches = candidates.filter { !$0.isDemo && $0.url == url }
                return matches.first { $0.id == preferring } ?? matches.first
            }
        case .demo: candidates.first { $0.isDemo }
        }
        guard let match else {
            if self.gateway == .demo { return .openDemo(sessionKey: self.sessionKey, messageId: self.messageId) }
            return .unknownGateway
        }
        guard let requested = self.sessionKey else { return .openGateway(match.id) }
        let key = resolveKey(match.id, requested)
        if verifySession, let keys = match.sessionKeys, !keys.isEmpty, !keys.contains(key) {
            return .unknownSession(gatewayId: match.id, sessionKey: requested)
        }
        return .openChat(Notifier.Target(gatewayId: match.id, sessionKey: key), messageId: self.messageId)
    }

    /// Resolves against live gateways, using each one's listed sessions and key aliases.
    @MainActor
    public func resolve(in gateways: [GatewayStore], verifySession: Bool = true, preferring: UUID? = nil) -> Resolution {
        let candidates = gateways.map {
            Candidate(id: $0.id, isDemo: $0.profile.isDemo,
                      sessionKeys: $0.sessions.isEmpty ? nil : Set($0.sessions.keys), url: $0.profile.url)
        }
        return self.resolve(in: candidates, verifySession: verifySession, preferring: preferring) { id, key in
            gateways.first { $0.id == id }?.resolveSessionKey(key) ?? key
        }
    }

    // MARK: Private

    private init?(values: [String: String]) {
        guard let raw = values[Key.gateway]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let gateway: Gateway
        if raw.lowercased() == Self.demoToken {
            gateway = .demo
        } else if let id = UUID(uuidString: raw) {
            gateway = .id(id)
        } else {
            return nil
        }
        self.init(gateway: gateway, sessionKey: values[Key.session], messageId: values[Key.message],
                  gatewayURL: values[Key.url])
    }

    private var fields: [(name: String, value: String)] {
        let gateway = switch self.gateway {
        case let .id(id): id.uuidString
        case .demo: Self.demoToken
        }
        var fields = [(Key.gateway, gateway)]
        if let key = self.sessionKey { fields.append((Key.session, key)) }
        if let id = self.messageId { fields.append((Key.message, id)) }
        if let url = self.gatewayURL { fields.append((Key.url, url)) }
        return fields.map { (name: $0.0, value: $0.1) }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
    }
}
