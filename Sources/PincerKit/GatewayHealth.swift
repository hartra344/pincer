import Foundation
import Observation

// MARK: Values

/// How the Gateway is doing, from the connection, the `health` payload and the last heartbeat.
public enum GatewayHealthLevel: String, Hashable, Sendable {
    case healthy
    case degraded
    case down
    case restarting

    public var label: String {
        switch self {
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        case .restarting: "Restarting"
        }
    }

    public var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .restarting: "arrow.clockwise.circle.fill"
        }
    }
}

/// One channel account in the `health` payload (`channels.<id>` or `channels.<id>.accounts.<id>`).
public struct GatewayChannelAccountHealth: Identifiable, Hashable, Sendable {
    public let accountId: String
    public let name: String?
    public let enabled: Bool?
    public let configured: Bool?
    public let running: Bool?
    public let connected: Bool?
    public let restartPending: Bool
    public let reconnectAttempts: Int?
    public let lastConnectedAt: Date?
    public let lastError: String?
    public let lifecycle: String?
    /// `channels.status` account snapshot fields (absent from `health`).
    public let linked: Bool?
    public let healthState: String?
    public let lastStartAt: Date?
    public let lastStopAt: Date?
    public let lastInboundAt: Date?
    public let lastOutboundAt: Date?
    public let lastProbeAt: Date?
    public let mode: String?
    /// `probe.ok` after `channels.status` with `probe: true`.
    public let probeOk: Bool?

    public var id: String { self.accountId }

    public init(_ json: JSONValue, fallbackId: String) {
        func date(_ key: String) -> Date? { json[key]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } }
        self.accountId = json["accountId"]?.text ?? fallbackId
        self.name = json["name"]?.text
        self.enabled = json["enabled"]?.bool
        self.configured = json["configured"]?.bool
        self.running = json["running"]?.bool
        self.connected = json["connected"]?.bool
        self.restartPending = json["restartPending"]?.bool == true
        self.reconnectAttempts = json["reconnectAttempts"]?.int
        self.lastConnectedAt = date("lastConnectedAt")
        self.lastError = json["lastError"]?.text
        self.lifecycle = json["lifecycle"]?.text
        self.linked = json["linked"]?.bool
        self.healthState = json["healthState"]?.text
        self.lastStartAt = date("lastStartAt")
        self.lastStopAt = date("lastStopAt")
        self.lastInboundAt = date("lastInboundAt")
        self.lastOutboundAt = date("lastOutboundAt")
        self.lastProbeAt = date("lastProbeAt")
        self.mode = json["mode"]?.text
        self.probeOk = json["probe"]?["ok"]?.bool
    }

    /// The latest message in or out.
    public var lastActivityAt: Date? {
        [self.lastInboundAt, self.lastOutboundAt].compactMap(\.self).max()
    }

    /// Enabled and set up, unless the Gateway says otherwise.
    public var isActive: Bool { self.enabled != false && self.configured != false }

    /// An active account that isn't running, lost its connection, or reported an error.
    public var hasProblem: Bool {
        self.isActive && (self.running == false || self.connected == false || self.lastError != nil)
    }
}

/// One channel (Discord, Telegram…) in the `health` payload, with its accounts.
public struct GatewayChannelHealth: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case connected
        case running
        case stopped
        case error
        case disabled
        case notConfigured
        case unknown

        public var label: String {
            switch self {
            case .connected: "Connected"
            case .running: "Running"
            case .stopped: "Stopped"
            case .error: "Error"
            case .disabled: "Disabled"
            case .notConfigured: "Not set up"
            case .unknown: "Unknown"
            }
        }
    }

    public let id: String
    public let label: String
    /// The channel-level summary, then each account when the channel lists them.
    public let summary: GatewayChannelAccountHealth
    public let accounts: [GatewayChannelAccountHealth]

    public init(id: String, label: String?, _ json: JSONValue) {
        self.id = id
        self.label = label ?? json["name"]?.text ?? ApprovalRecord.humanized(id)
        self.summary = GatewayChannelAccountHealth(json, fallbackId: "default")
        let accounts = json["accounts"]?.object ?? [:]
        self.accounts = accounts.keys.sorted().compactMap { key in
            guard let account = accounts[key], account.object != nil else { return nil }
            return GatewayChannelAccountHealth(account, fallbackId: key)
        }
    }

    /// The accounts whose health counts: the listed ones, else the channel itself.
    public var effectiveAccounts: [GatewayChannelAccountHealth] { self.accounts.isEmpty ? [self.summary] : self.accounts }

    public var problemAccounts: [GatewayChannelAccountHealth] { self.effectiveAccounts.filter(\.hasProblem) }

    public var restartPending: Bool { self.summary.restartPending || self.accounts.contains(where: \.restartPending) }

    public var lastError: String? { self.summary.lastError ?? self.effectiveAccounts.lazy.compactMap(\.lastError).first }

    public var status: Status {
        let accounts = self.effectiveAccounts
        let active = accounts.filter(\.isActive)
        if active.isEmpty {
            if accounts.contains(where: { $0.enabled == false }) { return .disabled }
            if accounts.contains(where: { $0.configured == false }) { return .notConfigured }
            return .unknown
        }
        if active.contains(where: { $0.lastError != nil }) { return .error }
        if active.contains(where: { $0.running == false || $0.connected == false }) { return .stopped }
        if active.contains(where: { $0.connected == true }) { return .connected }
        if active.contains(where: { $0.running == true }) { return .running }
        return .unknown
    }
}

/// The Gateway's `health` result (also `hello-ok.snapshot.health` and the `health` event).
/// Every field is optional: the hello snapshot is `{}` until the Gateway has computed it.
public struct GatewayHealthSummary: Hashable, Sendable {
    public struct PluginError: Hashable, Sendable {
        public let id: String
        public let error: String
    }

    public struct FailedQueue: Hashable, Sendable {
        public let queueName: String
        public let count: Int
    }

    public let ok: Bool?
    public let checkedAt: Date?
    public let durationMs: Int?
    public let channels: [GatewayChannelHealth]
    public let heartbeatSeconds: Int?
    /// Some agent has its heartbeat turned on (or, without agent details, a heartbeat interval is set).
    public let heartbeatEnabled: Bool
    public let pluginErrors: [PluginError]
    public let unavailablePlugins: [String]
    public let failedQueues: [FailedQueue]
    public let quarantinedEngines: [String]
    public let modelPricingState: String?
    public let sessionCount: Int?

    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.ok = json["ok"]?.bool
        self.checkedAt = json["ts"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.durationMs = json["durationMs"]?.int
        let channels = json["channels"]?.object ?? [:]
        let labels = json["channelLabels"]?.object ?? [:]
        let order = (json["channelOrder"]?.array ?? []).compactMap(\.text)
        var seen: Set<String> = []
        let ordered = (order + channels.keys.sorted()).filter { channels[$0] != nil && seen.insert($0).inserted }
        self.channels = ordered.compactMap { id in
            guard let entry = channels[id], entry.object != nil else { return nil }
            return GatewayChannelHealth(id: id, label: labels[id]?.text, entry)
        }
        let seconds = json["heartbeatSeconds"]?.int
        self.heartbeatSeconds = seconds
        if let agents = json["agents"]?.array, !agents.isEmpty {
            self.heartbeatEnabled = agents.contains { $0["heartbeat"]?["enabled"]?.bool == true }
        } else {
            self.heartbeatEnabled = (seconds ?? 0) > 0
        }
        let plugins = json["plugins"]
        self.pluginErrors = (plugins?["errors"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.text ?? entry.text else { return nil }
            return PluginError(id: id, error: entry["error"]?.text ?? "Failed to load")
        }
        self.unavailablePlugins = (plugins?["unavailable"]?.array ?? []).compactMap { $0["id"]?.text ?? $0.text }
        self.failedQueues = (json["deliveryQueues"]?["failed"]?.array ?? []).compactMap { entry in
            guard let count = entry["count"]?.int, count > 0 else { return nil }
            return FailedQueue(queueName: entry["queueName"]?.text ?? "delivery", count: count)
        }
        self.quarantinedEngines = (json["contextEngines"]?["quarantined"]?.array ?? []).compactMap {
            $0["engineId"]?.text ?? $0.text
        }
        self.modelPricingState = json["modelPricing"]?["state"]?.text
        self.sessionCount = json["sessions"]?["count"]?.int
    }

    public var restartPending: Bool { self.channels.contains(where: \.restartPending) }
}

/// `last-heartbeat` / the `heartbeat` event.
public struct GatewayHeartbeat: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case sent
        case okEmpty
        case okToken
        case skipped
        case failed
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "sent": self = .sent
            case "ok-empty": self = .okEmpty
            case "ok-token": self = .okToken
            case "skipped": self = .skipped
            case "failed": self = .failed
            default: self = .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .sent: "Sent"
            case .okEmpty: "OK, nothing to do"
            case .okToken: "OK"
            case .skipped: "Skipped"
            case .failed: "Failed"
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }
    }

    public let at: Date?
    public let status: Status
    public let to: String?
    public let channel: String?
    public let durationMs: Int?
    public let reason: String?
    public let indicatorType: String?

    /// Nil for `null` (no heartbeat yet) and anything that isn't an object.
    public init?(_ json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        self.at = json["ts"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.status = Status(json["status"]?.text ?? "unknown")
        self.to = json["to"]?.text
        self.channel = json["channel"]?.text
        self.durationMs = json["durationMs"]?.int
        self.reason = json["reason"]?.text
        self.indicatorType = json["indicatorType"]?.text
    }

    public var isFailure: Bool { self.status == .failed || self.indicatorType == "error" }

    /// Late when older than twice the heartbeat interval while heartbeats are on.
    public static func isStale(_ heartbeat: GatewayHeartbeat?, heartbeatSeconds: Int?, enabled: Bool, now: Date) -> Bool {
        guard enabled, let seconds = heartbeatSeconds, seconds > 0, let at = heartbeat?.at else { return false }
        return now.timeIntervalSince(at) > Double(seconds) * 2
    }
}

/// One entry of `system-presence` / `hello-ok.snapshot.presence`: a client or node connected to the Gateway.
public struct GatewayPresenceEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String?
    public let host: String?
    public let clientId: String?
    public let ip: String?
    public let version: String?
    public let platform: String?
    public let deviceFamily: String?
    public let mode: String?
    public let deviceId: String?
    public let instanceId: String?
    public let roles: [String]
    public let scopes: [String]
    public let userName: String?
    public let userEmail: String?
    public let seenAt: Date?
    public let onlineSince: Date?
    public let lastActivityAt: Date?
    public let lastInputSeconds: Int?

    public init?(_ json: JSONValue, index: Int = 0) {
        guard json.object != nil else { return nil }
        func date(_ key: String) -> Date? { json[key]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } }
        self.text = json["text"]?.text
        self.host = json["host"]?.text
        self.clientId = json["clientId"]?.text
        self.ip = json["ip"]?.text
        self.version = json["version"]?.text
        self.platform = json["platform"]?.text
        self.deviceFamily = json["deviceFamily"]?.text
        self.mode = json["mode"]?.text
        self.deviceId = json["deviceId"]?.text
        self.instanceId = json["instanceId"]?.text
        self.roles = (json["roles"]?.array ?? []).compactMap(\.text)
        self.scopes = (json["scopes"]?.array ?? []).compactMap(\.text)
        self.userName = json["user"]?["name"]?.text
        self.userEmail = json["user"]?["email"]?.text
        self.seenAt = date("ts")
        self.onlineSince = date("onlineSince")
        self.lastActivityAt = date("lastActivityAt")
        self.lastInputSeconds = json["lastInputSeconds"]?.int
        let clientId = self.clientId, host = self.host, ip = self.ip
        self.id = self.instanceId ?? self.deviceId.map { "\($0)|\(clientId ?? "")" }
            ?? [clientId, host, ip].compactMap { $0 }.joined(separator: "|").nilIfEmpty
            ?? "presence-\(index)"
    }

    public static func list(_ json: JSONValue?) -> [GatewayPresenceEntry] {
        let raw = json?.array ?? json?["presence"]?.array ?? json?["entries"]?.array ?? []
        var seen: Set<String> = []
        return raw.enumerated().compactMap { GatewayPresenceEntry($1, index: $0) }.filter { seen.insert($0.id).inserted }
    }

    public var displayName: String {
        self.userName ?? self.host ?? self.clientId.map(Self.clientName) ?? self.text ?? "Unknown client"
    }

    /// "macOS · Mac", from whichever of platform and device family came.
    public var deviceSummary: String? {
        let parts = [self.platform.map(Self.platformName), self.deviceFamily].compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            unique.append(part)
        }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    /// "ui · operator", from mode and roles.
    public var roleSummary: String? {
        let parts = ([self.mode] + self.roles.map(Optional.some)).compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    public func isThisDevice(deviceId: String?, instanceId: String?) -> Bool {
        if let deviceId, let own = self.deviceId, own == deviceId { return true }
        if let instanceId, let own = self.instanceId, own == instanceId { return true }
        return false
    }

    static func platformName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "macos", "darwin": "macOS"
        case "ios": "iOS"
        case "ipados": "iPadOS"
        case "linux": "Linux"
        case "windows", "win32": "Windows"
        case "android": "Android"
        case "web", "browser": "Web"
        default: raw
        }
    }

    static func clientName(_ raw: String) -> String {
        switch raw {
        case "openclaw-macos": "OpenClaw (macOS)"
        case "openclaw-ios": "OpenClaw (iOS)"
        case "openclaw-control-ui", "control-ui": "Control UI"
        case "cli", "openclaw-cli": "OpenClaw CLI"
        default: raw
        }
    }
}

/// `gateway.restart.request`'s answer.
public struct GatewayRestartResult: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case scheduled
        case deferred
        case coalesced
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "scheduled": self = .scheduled
            case "deferred": self = .deferred
            case "coalesced": self = .coalesced
            default: self = .other(raw)
            }
        }
    }

    public let status: Status
    public let safe: Bool?
    /// Work the Gateway waits for before restarting (`preflight.counts.totalActive`).
    public let activeCount: Int
    public let blockers: [String]
    public let summary: String?

    public init(_ json: JSONValue) {
        self.status = Status(json["status"]?.text ?? "scheduled")
        let preflight = json["preflight"]
        self.safe = preflight?["safe"]?.bool
        self.blockers = (preflight?["blockers"]?.array ?? []).compactMap { $0["message"]?.text ?? $0.text }
        if let total = preflight?["counts"]?["totalActive"]?.int {
            self.activeCount = max(0, total)
        } else if let counts = preflight?["counts"]?.object {
            self.activeCount = counts.values.compactMap(\.int).filter { $0 > 0 }.reduce(0, +)
        } else {
            self.activeCount = self.blockers.count
        }
        self.summary = preflight?["summary"]?.text
    }

    /// "Waiting for 2 active tasks: restart deferred: 1 embedded run"
    public var waitingMessage: String {
        let count = max(self.activeCount, 1)
        let head = "Waiting for \(count) active task\(count == 1 ? "" : "s")"
        let detail = self.summary ?? (self.blockers.isEmpty ? nil : self.blockers.joined(separator: "; "))
        return detail.map { "\(head): \($0)" } ?? head
    }
}

/// Something wrong with the Gateway, as a row on the Health page.
public struct GatewayHealthIssue: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case channel
        case plugin
        case delivery
        case contextEngine
        case heartbeat
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    /// What a "Dismiss until it changes" remembers (see `GatewayHealthRules.isDismissed`).
    public let fingerprint: String

    public init(id: String, kind: Kind, title: String, detail: String? = nil, fingerprint: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.fingerprint = fingerprint
    }

    /// Channel accounts and plugins can be ignored for good; lost deliveries, engines and heartbeats can't.
    public var canAlwaysIgnore: Bool { Self.canAlwaysIgnore(kind: self.kind) }

    static func canAlwaysIgnore(kind: Kind) -> Bool { kind == .channel || kind == .plugin }

    /// Channel, plugin and context engine problems are often fixed by a restart.
    public var offersRestart: Bool { self.kind == .channel || self.kind == .plugin || self.kind == .contextEngine }

    /// The channel account a channel issue is about (`channel:<channel>:<accountId>`).
    public var channelAccount: ChannelAccountKey? { ChannelAccountKey(healthIssueId: self.id) }

    /// Channel account issues offer Reconnect Account and Show in Channel Status.
    public var offersReconnect: Bool { self.channelAccount != nil }

    /// The kind an issue id stands for, from its prefix.
    public static func kind(ofId id: String) -> Kind? {
        if id.hasPrefix("channel:") { return .channel }
        if id.hasPrefix("plugin:") || id.hasPrefix("plugin-unavailable:") { return .plugin }
        if id.hasPrefix("queue:") { return .delivery }
        if id.hasPrefix("engine:") { return .contextEngine }
        if id.hasPrefix("heartbeat:") { return .heartbeat }
        return nil
    }

    /// A stand-in row for an ignored issue the Gateway isn't reporting right now, titled from its id.
    public static func placeholder(id: String) -> GatewayHealthIssue {
        let kind = Self.kind(ofId: id) ?? .channel
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title: String
        switch parts.first {
        case "channel" where parts.count == 3:
            title = "\(ApprovalRecord.humanized(parts[1])) (\(parts[2]))"
        case "plugin", "plugin-unavailable":
            title = "Plugin \(id.drop { $0 != ":" }.dropFirst())"
        default:
            title = id
        }
        return GatewayHealthIssue(id: id, kind: kind, title: title)
    }

    public var symbol: String {
        switch self.kind {
        case .channel: "bubble.left.and.exclamationmark.bubble.right"
        case .plugin: "puzzlepiece.extension"
        case .delivery: "tray.full"
        case .contextEngine: "memorychip"
        case .heartbeat: "waveform.path.ecg"
        }
    }
}

/// A stored dismissal (`pincer.healthDismissals`): hidden until the issue changes, or for good.
public enum GatewayHealthDismissal: Hashable, Sendable {
    case untilChanged(String)
    case always

    public init?(stored: String) {
        if stored == "always" {
            self = .always
        } else if stored.hasPrefix("until:") {
            self = .untilChanged(String(stored.dropFirst("until:".count)))
        } else {
            return nil
        }
    }

    public var stored: String {
        switch self {
        case .always: "always"
        case let .untilChanged(fingerprint): "until:\(fingerprint)"
        }
    }
}
