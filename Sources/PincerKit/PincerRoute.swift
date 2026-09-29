import Foundation

/// Where a `pincer://` link, a Handoff activity, a notification, or a shortcut takes the app.
/// Routes only ever navigate: they never send, approve, or fill in anything.
///
/// URL form: `pincer://open?gateway=<UUID|demo>&session=<key>[&message=<id>][&url=<address>][&host=<name>]`.
/// The demo gateway's id differs per install, so links to it say `demo` instead. Every other id is
/// per install too, so a link also carries the gateway's address and the host name the gateway
/// reports for itself, which is how another device finds its own copy of that gateway (#375).
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
    /// The host name the gateway reports for itself (its own `system-presence` entry), the same
    /// whichever address a device uses to reach it. `normalizedGatewayHost` form.
    public var gatewayHost: String?

    public init(gateway: Gateway, sessionKey: String? = nil, messageId: String? = nil, gatewayURL: String? = nil,
                gatewayHost: String? = nil)
    {
        self.gateway = gateway
        self.sessionKey = sessionKey.flatMap { $0.isEmpty ? nil : $0 }
        self.messageId = messageId.flatMap { $0.isEmpty ? nil : $0 }
        self.gatewayURL = gateway == .demo ? nil : gatewayURL.flatMap(Self.normalizedGatewayURL)
        self.gatewayHost = gateway == .demo ? nil : gatewayHost.flatMap(Self.normalizedGatewayHost)
    }

    /// A route to a chat; `isDemo` writes the gateway as `demo` so the link works on any device.
    public init(target: Notifier.Target, isDemo: Bool = false, messageId: String? = nil, gatewayURL: String? = nil,
                gatewayHost: String? = nil)
    {
        self.init(gateway: isDemo ? .demo : .id(target.gatewayId), sessionKey: target.sessionKey,
                  messageId: messageId, gatewayURL: gatewayURL, gatewayHost: gatewayHost)
    }

    /// `scheme://host[:port][/path]` of a `ws`/`wss`/`http`/`https` gateway address: scheme and
    /// host lowercased, a trailing dot on the host, default ports and a trailing slash dropped, and
    /// any `user:password@`, query, or fragment removed. An address saved without a scheme gets the
    /// one Pincer connects with (`wss` for `*.ts.net`, else `ws`). Nil for anything else.
    public static func normalizedGatewayURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") {
            let host = text.split(separator: "/").first.map { $0.split(separator: ":").first.map(String.init) ?? "" } ?? ""
            text = (host.lowercased().hasSuffix(".ts.net") ? "wss://" : "ws://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme),
              var host = components.percentEncodedHost?.lowercased()
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
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

    /// A host name as a gateway reports it: trimmed, lowercased, without a trailing dot. Nil when
    /// empty, too long, or not plausibly a host name or address.
    public static func normalizedGatewayHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ Self.hostCharacters.contains($0) })
        else { return nil }
        return host
    }

    /// The machine a host name or address points at, for telling that `travis-mbp.local`,
    /// `Travis-MBP` and `travis-mbp.tail1234.ts.net` are one computer: the first DNS label of a
    /// name, or the whole address for an IP literal. Nil for loopback, which means "this device"
    /// and so says nothing on another one.
    public static func machineName(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "localhost", host != "::1", !host.hasSuffix(".localhost") else { return nil }
        if host.contains(":") { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            return labels[0] == "127" ? nil : host
        }
        return labels.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
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
        public static let host = "host"
    }

    /// Fixed wording for what a route couldn't do. Never includes ids from the link.
    public enum Notice {
        public static var unknownGateway: String { L("That link points to a Gateway that isn’t set up on this device.") }
        public static var unknownSession: String { L("That chat isn’t available on this Gateway anymore.") }
        public static var unknownMessage: String { L("Couldn’t find that message.") }
        public static var invalidLink: String { L("Pincer couldn’t open that link.") }
        public static var linkCopied: String { L("Link copied") }
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

    /// The Handoff payload: gateway, session, address and host only. Handoff moves the chat, never a
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
        for key in [Key.gateway, Key.session, Key.message, Key.url, Key.host] {
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
        /// The host name it last reported for itself, matched when the id doesn't.
        public let gatewayHost: String?

        public init(id: UUID, isDemo: Bool, sessionKeys: Set<String>?, url: String? = nil, gatewayHost: String? = nil) {
            self.id = id
            self.isDemo = isDemo
            self.sessionKeys = sessionKeys
            self.url = url.flatMap(PincerRoute.normalizedGatewayURL)
            self.gatewayHost = gatewayHost.flatMap(PincerRoute.normalizedGatewayHost)
        }
    }

    /// Pure resolution against `candidates`. `resolveKey` maps aliases (e.g. `agent:x:main`) to
    /// a gateway's real key; identity by default. `verifySession: false` trusts the session key
    /// (for routes Pincer made itself, e.g. a notification for a chat not listed yet); links and
    /// Handoff from outside verify it. Among equally good matches, `preferring` wins.
    ///
    /// Ids are per install, so a gateway from another device is found by, best first: the host
    /// name it reports for itself, its exact address, its address whatever the scheme, the machine
    /// its address names, and last, the only gateway here that has the chat (see `matchElsewhere`).
    public func resolve(in candidates: [Candidate], verifySession: Bool = true, preferring: UUID? = nil,
                        resolveKey: (UUID, String) -> String = { $1 }) -> Resolution {
        let match: Candidate? = switch self.gateway {
        case let .id(id):
            candidates.first { $0.id == id }
                ?? self.matchElsewhere(candidates.filter { !$0.isDemo }, preferring: preferring, resolveKey: resolveKey)
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
                      sessionKeys: $0.sessions.isEmpty ? nil : Set($0.sessions.keys), url: $0.profile.url,
                      gatewayHost: $0.gatewayHost)
        }
        return self.resolve(in: candidates, verifySession: verifySession, preferring: preferring) { id, key in
            gateways.first { $0.id == id }?.resolveSessionKey(key) ?? key
        }
    }

    // MARK: Private

    /// The gateway on this device that a route from another device means. Each candidate scores
    /// what it shares with the route; the best wins, ties going to the one that has the chat, then
    /// `preferring`, then list order. With no shared host or address, the one gateway that has the
    /// chat is it, unless the chat is a main chat, which every gateway has.
    private func matchElsewhere(_ candidates: [Candidate], preferring: UUID?,
                                resolveKey: (UUID, String) -> String) -> Candidate? {
        func holdsChat(_ candidate: Candidate) -> Bool {
            guard let key = self.sessionKey, let keys = candidate.sessionKeys else { return false }
            return keys.contains(resolveKey(candidate.id, key))
        }
        let names = Self.machineNames(url: self.gatewayURL, host: self.gatewayHost)
        let address = self.gatewayURL.flatMap(Self.addressKey)
        let scored = candidates.map { candidate -> (Candidate, Int) in
            var score = 0
            if let host = self.gatewayHost, host == candidate.gatewayHost { score += 8 }
            if let url = self.gatewayURL, url == candidate.url { score += 4 }
            if let address, address == candidate.url.flatMap(Self.addressKey) { score += 2 }
            if !names.isDisjoint(with: Self.machineNames(url: candidate.url, host: candidate.gatewayHost)) { score += 1 }
            return (candidate, score)
        }
        if let best = scored.map(\.1).max(), best > 0 {
            let top = scored.filter { $0.1 == best }.map(\.0)
            let holding = top.filter(holdsChat)
            let pool = holding.isEmpty ? top : holding
            return pool.first { $0.id == preferring } ?? pool.first
        }
        guard let key = self.sessionKey, !Self.isMainChat(key) else { return nil }
        let holders = candidates.filter(holdsChat)
        return holders.count == 1 ? holders.first : nil
    }

    /// Host, effective port and path of a normalized address: the same server over ws or wss.
    private static func addressKey(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme,
              let host = components.percentEncodedHost else { return nil }
        let port = components.port ?? (["ws", "http"].contains(scheme) ? 80 : 443)
        return "\(host):\(port)\(components.path)"
    }

    private static func machineNames(url: String?, host: String?) -> Set<String> {
        var names: Set<String> = []
        if let host, let name = self.machineName(host) { names.insert(name) }
        if let url, let host = URLComponents(string: url)?.host, let name = self.machineName(host) { names.insert(name) }
        return names
    }

    /// `main`, `global` and each agent's `agent:<id>:main`: chats every gateway has.
    private static func isMainChat(_ key: String) -> Bool {
        if ["main", "global", "unknown"].contains(key) { return true }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "agent" && parts[2] == "main"
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")

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
                  gatewayURL: values[Key.url], gatewayHost: values[Key.host])
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
        if let host = self.gatewayHost { fields.append((Key.host, host)) }
        return fields.map { (name: $0.0, value: $0.1) }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
    }
}
