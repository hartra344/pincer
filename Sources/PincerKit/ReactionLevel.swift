import Foundation

/// How freely the agent reacts on a bridged channel (`channels.<channel>.reactionLevel`).
/// Mirrors upstream `ReactionLevel` (src/utils/reaction-level.ts).
public enum ReactionLevel: String, CaseIterable, Sendable, Hashable, Identifiable {
    case off, ack, minimal, extensive

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .ack: "Acknowledge only"
        case .minimal: "Minimal"
        case .extensive: "Extensive"
        }
    }

    public var detail: String {
        switch self {
        case .off: "The agent never reacts."
        case .ack: "The agent doesn't react itself. The 👀 acknowledgement still shows if it's set up."
        case .minimal: "The agent reacts now and then, when it fits."
        case .extensive: "The agent reacts freely."
        }
    }

    /// WhatsApp and Signal also drop the 👀 acknowledgement at "Off"; Telegram's ignores this setting.
    public func offAlsoStopsAcknowledgement(channel: String) -> Bool {
        self == .off && ["whatsapp", "signal"].contains(channel.lowercased())
    }
}

/// Which channels take a reaction level, and how a level resolves. Only Telegram, WhatsApp and
/// Signal declare it upstream; Discord uses `actions.reactions` instead.
public enum ReactionLevels {
    public enum Source: String, Sendable, Hashable {
        case account, channel, `default`
    }

    public struct Effective: Sendable, Hashable {
        public let level: ReactionLevel
        public let source: Source
        /// The stored value at `source` isn't a valid level, so the channel's fallback applies.
        public let isInvalid: Bool
    }

    public static let supportedChannels: [String] = ["telegram", "whatsapp", "signal"]
    public static let key = "reactionLevel"

    public static func supports(channel: String?) -> Bool {
        guard let channel else { return false }
        return self.supportedChannels.contains(channel.lowercased())
    }

    /// The level when nothing is configured.
    public static func defaultLevel(channel: String) -> ReactionLevel { .minimal }

    /// What an unrecognised value falls back to: Telegram acknowledges, the others react sparingly.
    public static func invalidFallback(channel: String) -> ReactionLevel {
        channel.lowercased() == "telegram" ? .ack : .minimal
    }

    /// The config path of the setting: the channel's, or one account's.
    public static func path(channel: String, account: String? = nil) -> [String] {
        guard let account, !account.isEmpty else { return ["channels", channel, self.key] }
        return ["channels", channel, "accounts", account, self.key]
    }

    /// The level stored at `path`, if any, as (parsed level, whether it was set but unusable).
    private static func stored(_ config: JSONValue?, at path: [String]) -> (level: ReactionLevel?, isSet: Bool) {
        var node: JSONValue? = config
        for part in path { node = node?[part] }
        guard let value = node, !value.isNull else { return (nil, false) }
        guard let text = value.string else { return (nil, true) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, false) }
        return (ReactionLevel(rawValue: trimmed), true)
    }

    /// The level the agent gets: the account's own value, else the channel's, else the default.
    public static func effective(config: JSONValue?, channel: String, account: String? = nil) -> Effective {
        let fallback = self.invalidFallback(channel: channel)
        var layers: [(Source, [String])] = []
        if let account, !account.isEmpty { layers.append((.account, self.path(channel: channel, account: account))) }
        layers.append((.channel, self.path(channel: channel)))
        for (source, path) in layers {
            let found = self.stored(config, at: path)
            if let level = found.level { return Effective(level: level, source: source, isInvalid: false) }
            if found.isSet { return Effective(level: fallback, source: source, isInvalid: true) }
        }
        return Effective(level: self.defaultLevel(channel: channel), source: .default, isInvalid: false)
    }

    /// The `config.patch` body for one setting. A `nil` level removes the key (patch `null`).
    public static func patch(channel: String, account: String? = nil, level: ReactionLevel?) -> JSONValue {
        let value: JSONValue = level.map { .string($0.rawValue) } ?? .null
        var node: JSONValue = .object([self.key: value])
        if let account, !account.isEmpty { node = .object(["accounts": .object([account: node])]) }
        return .object(["channels": .object([channel: node])])
    }

    /// Whether `path` is one of the settings this control edits (so the schema editor can leave it out).
    public static func isControlled(path: [String]) -> Bool {
        guard path.last == self.key, path.first == "channels", path.count >= 3, self.supports(channel: path[1]) else { return false }
        return path.count == 3 || (path.count == 5 && path[2] == "accounts")
    }

    /// The channel and account a config path under `channels` names, for the page that edits it.
    public static func target(for path: [String]) -> (channel: String, account: String?)? {
        guard path.first == "channels", path.count >= 2, self.supports(channel: path[1]) else { return nil }
        if path.count == 2 { return (path[1], nil) }
        if path.count == 4, path[2] == "accounts" { return (path[1], path[3]) }
        return nil
    }

    /// The account to edit for a chat: only one the config actually lists, else the channel's own setting.
    public static func editableAccount(config: JSONValue?, channel: String, account: String?) -> String? {
        guard let account, !account.isEmpty, config?["channels"]?[channel]?["accounts"]?[account] != nil else { return nil }
        return account
    }

    public static func displayName(channel: String) -> String {
        switch channel.lowercased() {
        case "whatsapp": "WhatsApp"
        case "telegram": "Telegram"
        case "signal": "Signal"
        default: channel.capitalized
        }
    }

    /// The chat's account when it has its own `reactionLevel`; otherwise nil, so the channel's setting is edited.
    public static func overridingAccount(config: JSONValue?, channel: String, account: String?) -> String? {
        guard let account = self.editableAccount(config: config, channel: channel, account: account),
              config?["channels"]?[channel]?["accounts"]?[account]?[self.key] != nil else { return nil }
        return account
    }

    /// A chat's channel and account from its session row, when it's bridged on a supported channel.
    public static func target(of row: SessionRow) -> (channel: String, account: String?)? {
        let name = row.channel ?? row.raw["lastChannel"]?.text
        guard let channel = name?.lowercased(), self.supports(channel: channel) else { return nil }
        let account = row.raw["lastAccountId"]?.text ?? row.raw["deliveryContext"]?["accountId"]?.text
            ?? row.raw["origin"]?["accountId"]?.text
        return (channel, account)
    }
}

public extension GatewayStore {
    /// Whether reaction levels can be written: `operator.admin`, and `config.patch` unless the Gateway lists no methods.
    var canEditReactionLevels: Bool {
        guard self.settings.canEdit else { return false }
        guard let methods = self.hello?.methods, !methods.isEmpty else { return true }
        return methods.contains("config.patch")
    }
}
