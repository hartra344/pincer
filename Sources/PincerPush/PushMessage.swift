import Foundation

/// A Gateway Web Push notification (`{title, body, tag, url}`), as delivered through the relay.
///
/// The relay puts the still-encrypted Web Push body in the APNs payload under `pincer.p` with the
/// gateway id under `pincer.g`. The Gateway sends only generic copy plus a Control UI path, so the
/// app learns which chat or approval it's about and loads the content itself when opened.
public struct PushMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case chat
        case approval(id: String, pending: Bool)
        case other
    }

    public let gatewayId: UUID
    public let title: String
    public let body: String
    public let tag: String?
    public let kind: Kind
    /// Exact session key, or `agent:<id>:main` when the path names an agent's main chat.
    public let sessionKey: String?

    public init?(json: Data, gatewayId: UUID) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let body = object["body"] as? String
        guard title != nil || body != nil else { return nil }
        self.gatewayId = gatewayId
        self.title = title ?? "OpenClaw"
        self.body = body ?? ""
        self.tag = object["tag"] as? String
        let route = Self.route(object["url"] as? String ?? "")
        self.sessionKey = route.sessionKey
        switch route.approvalId {
        case let id?: self.kind = .approval(id: id, pending: !self.title.hasSuffix("approval updated"))
        case nil: self.kind = route.sessionKey == nil ? .other : .chat
        }
    }

    /// Decrypts the relay's APNs payload with this device's keys for that gateway.
    public init?(apnsPayload userInfo: [AnyHashable: Any], keys: (UUID) -> WebPushKeys? = PushKeyStore.keys(for:)) {
        guard let pincer = userInfo["pincer"] as? [String: Any],
              let gateway = (pincer["g"] as? String).flatMap(UUID.init(uuidString:)),
              let body = (pincer["p"] as? String).flatMap({ Data(base64URL: $0) }),
              let keys = keys(gateway),
              let plaintext = try? WebPush.decrypt(body, keys: keys)
        else { return nil }
        self.init(json: plaintext, gatewayId: gateway)
    }

    /// Matches `Notifier`'s local notifications, so opening a chat clears its pushes too.
    public var threadIdentifier: String {
        "\(self.gatewayId.uuidString)|\(self.sessionKey ?? "gateway")"
    }

    /// `approval` (Allow once, Always allow, Deny) for a pending approval, as registered by `Notifier`.
    /// Pushes don't say which decisions are allowed, so all three are offered.
    public var categoryIdentifier: String {
        if case .approval(_, true) = self.kind { return "approval" }
        return "reply"
    }

    /// Read by `Notifier` when the notification is opened or acted on.
    public var userInfo: [String: String] {
        var info = ["gateway": self.gatewayId.uuidString, "push": "1"]
        if let sessionKey { info["session"] = sessionKey }
        if case let .approval(id, _) = self.kind { info["approval"] = id }
        return info
    }

    /// Parses Control UI paths: `chat/<agent>[/~key/<rest>|/<a>/<b>…]` and `approve/<id>`.
    /// A `#gatewayUrl=…` fragment and an absolute base are ignored.
    public static func route(_ url: String) -> (sessionKey: String?, approvalId: String?) {
        var path = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if let parsed = URL(string: path), parsed.scheme != nil { path = parsed.path }
        let segments = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if let index = segments.lastIndex(of: "approve"), index + 1 < segments.count {
            return (nil, segments[index + 1])
        }
        guard let index = segments.firstIndex(of: "chat"), index + 1 < segments.count else { return (nil, nil) }
        let agent = segments[index + 1].lowercased()
        let rest = Array(segments[(index + 2)...])
        guard !agent.isEmpty, !rest.contains(where: \.isEmpty) else { return (nil, nil) }
        if rest.isEmpty { return ("agent:\(agent):main", nil) }
        if rest.first == "~key" {
            guard rest.count == 2 else { return (nil, nil) }
            return ("agent:\(agent):\(rest[1])", nil)
        }
        return ("agent:\(agent):\(rest.joined(separator: ":"))", nil)
    }
}
