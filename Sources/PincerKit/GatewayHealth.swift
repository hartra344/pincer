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

    public var id: String { self.accountId }

    public init(_ json: JSONValue, fallbackId: String) {
        self.accountId = json["accountId"]?.text ?? fallbackId
        self.name = json["name"]?.text
        self.enabled = json["enabled"]?.bool
        self.configured = json["configured"]?.bool
        self.running = json["running"]?.bool
        self.connected = json["connected"]?.bool
        self.restartPending = json["restartPending"]?.bool == true
        self.reconnectAttempts = json["reconnectAttempts"]?.int
        self.lastConnectedAt = json["lastConnectedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.lastError = json["lastError"]?.text
        self.lifecycle = json["lifecycle"]?.text
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

// MARK: Level

public enum GatewayHealthRules {
    /// Where an issue comes from, so a fresh result only prunes dismissals it could have reported.
    public enum Source: Hashable, Sendable {
        case health
        case heartbeat

        public init?(issueId id: String) {
            guard let kind = GatewayHealthIssue.kind(ofId: id) else { return nil }
            self = kind == .heartbeat ? .heartbeat : .health
        }
    }

    /// Whether a stored dismissal hides the issue. Failed deliveries stay hidden until the count goes
    /// up; everything else until its fingerprint differs. `always` only counts for channels and plugins.
    public static func isDismissed(_ issue: GatewayHealthIssue, by dismissal: GatewayHealthDismissal?) -> Bool {
        switch dismissal {
        case nil: return false
        case .always: return issue.canAlwaysIgnore
        case let .untilChanged(fingerprint):
            if issue.kind == .delivery {
                guard let dismissed = Self.count(fingerprint), let current = Self.count(issue.fingerprint) else {
                    return fingerprint == issue.fingerprint
                }
                return current <= dismissed
            }
            return fingerprint == issue.fingerprint
        }
    }

    private static func count(_ fingerprint: String) -> Int? {
        guard fingerprint.hasPrefix("count=") else { return nil }
        return Int(fingerprint.dropFirst("count=".count))
    }

    /// Whether a stored value is an `always` that counts, which pruning keeps.
    static func isAlways(id: String, stored: String) -> Bool {
        guard GatewayHealthDismissal(stored: stored) == .always, let kind = GatewayHealthIssue.kind(ofId: id) else { return false }
        return GatewayHealthIssue.canAlwaysIgnore(kind: kind)
    }

    /// Drops dismissals for issues of `source` that a fresh result no longer reports. Other sources,
    /// unknown ids and `always` entries are kept.
    public static func pruned(_ dismissals: [String: String], current: [GatewayHealthIssue], source: Source) -> [String: String] {
        let reported = Set(current.map(\.id))
        return dismissals.filter { id, stored in
            guard Source(issueId: id) == source else { return true }
            return reported.contains(id) || Self.isAlways(id: id, stored: stored)
        }
    }

    /// Every reason the Gateway counts as degraded, in display order.
    public static func issues(health: GatewayHealthSummary?, heartbeat: GatewayHeartbeat?, now: Date) -> [GatewayHealthIssue] {
        var issues: [GatewayHealthIssue] = []
        if let health {
            for channel in health.channels {
                for account in channel.problemAccounts {
                    let who = channel.accounts.isEmpty || channel.accounts.count == 1 && account.accountId == "default"
                        ? channel.label : "\(channel.label) (\(account.name ?? account.accountId))"
                    let title = account.running == false ? "\(who) isn't running"
                        : account.connected == false ? "\(who) isn't connected" : "\(who) reported an error"
                    let state = account.running == false ? "not-running" : account.connected == false ? "not-connected" : "error"
                    issues.append(.init(id: "channel:\(channel.id):\(account.accountId)", kind: .channel, title: title,
                                        detail: account.lastError, fingerprint: "state=\(state)"))
                }
            }
            for plugin in health.pluginErrors {
                issues.append(.init(id: "plugin:\(plugin.id)", kind: .plugin, title: "Plugin \(plugin.id) failed to load",
                                    detail: plugin.error, fingerprint: "error=\(plugin.error)"))
            }
            for id in health.unavailablePlugins {
                issues.append(.init(id: "plugin-unavailable:\(id)", kind: .plugin, title: "Plugin \(id) is unavailable",
                                    detail: "It's configured but couldn't be verified.", fingerprint: "unavailable"))
            }
            for queue in health.failedQueues {
                issues.append(.init(id: "queue:\(queue.queueName)", kind: .delivery,
                                    title: "\(queue.count) failed deliver\(queue.count == 1 ? "y" : "ies")",
                                    detail: "Queue: \(queue.queueName)", fingerprint: "count=\(queue.count)"))
            }
            for engine in health.quarantinedEngines {
                issues.append(.init(id: "engine:\(engine)", kind: .contextEngine, title: "Context engine \(engine) is quarantined",
                                fingerprint: "quarantined"))
            }
        }
        if let heartbeat, heartbeat.isFailure {
            issues.append(.init(id: "heartbeat:failed", kind: .heartbeat, title: "The last heartbeat failed",
                                detail: heartbeat.reason, fingerprint: "reason=\(heartbeat.reason ?? "")"))
        }
        if GatewayHeartbeat.isStale(heartbeat, heartbeatSeconds: health?.heartbeatSeconds,
                                    enabled: health?.heartbeatEnabled ?? false, now: now)
        {
            issues.append(.init(id: "heartbeat:late", kind: .heartbeat, title: "Heartbeat is late",
                                detail: health?.heartbeatSeconds.map { "Expected every \(Self.duration(seconds: $0))." },
                                fingerprint: "every=\(health?.heartbeatSeconds.map(String.init) ?? "")"))
        }
        return issues
    }

    /// Down when not connected (or `health` answers UNAVAILABLE), Restarting from a restart request
    /// or `shutdown` until the next hello, Degraded with any issue, else Healthy.
    public static func level(connection: ConnectionState, restarting: Bool, healthUnavailable: Bool,
                             issueCount: Int) -> GatewayHealthLevel
    {
        if restarting { return .restarting }
        if connection != .connected || healthUnavailable { return .down }
        return issueCount > 0 ? .degraded : .healthy
    }

    static func duration(seconds: Int) -> String {
        if seconds % 3600 == 0, seconds >= 3600 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0, seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

// MARK: Model

/// Gateway Health for one Gateway: the level and why, version, uptime, last heartbeat, channels,
/// connected clients, and a safe restart (`gateway.restart.request`).
@MainActor
@Observable
public final class GatewayHealthModel {
    /// Parts of the page that come from separate methods, and can be missing on older Gateways.
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case health
        case heartbeat
        case presence
        case restart

        var method: String {
            switch self {
            case .health: "health"
            case .heartbeat: "last-heartbeat"
            case .presence: "system-presence"
            case .restart: "gateway.restart.request"
            }
        }
    }

    public enum RestartState: Hashable, Sendable {
        case idle
        case requesting
        /// Deferred: the Gateway restarts once active work drains.
        case waiting(String)
        /// Accepted; `coalesced` when a restart was already on its way.
        case scheduled(coalesced: Bool)
        /// `shutdown` came, or the socket closed after a request.
        case restarting
        case reconnecting
        /// Still reconnecting a minute after the Gateway went away.
        case notBack
        case restarted(uptimeMs: Int?)
        case failed(String)

        /// From the request (or `shutdown`) until the next hello.
        public var isInProgress: Bool {
            switch self {
            case .requesting, .waiting, .scheduled, .restarting, .reconnecting, .notBack: true
            default: false
            }
        }

        public var message: String? {
            switch self {
            case .idle: nil
            case .requesting: "Requesting restart…"
            case let .waiting(message): message
            case .scheduled(coalesced: true): "Restart already scheduled"
            case .scheduled: "Restarting…"
            case .restarting: "Restarting Gateway…"
            case .reconnecting: "Reconnecting…"
            case .notBack: "Gateway hasn't come back yet"
            case .restarted: "Gateway restarted"
            case let .failed(message): message
            }
        }
    }

    /// The compact row under the gateway in the sidebar; nil when there's nothing to say.
    public enum Indicator: Hashable, Sendable {
        case degraded(issues: Int)
        case restartNeeded
        case restarting
        case reconnecting
        case notBack

        public var message: String {
            switch self {
            case let .degraded(count): "Gateway degraded · \(count) issue\(count == 1 ? "" : "s")"
            case .restartNeeded: "Restart needed to apply changes"
            case .restarting: "Restarting Gateway…"
            case .reconnecting: "Reconnecting…"
            case .notBack: "Gateway hasn't come back yet"
            }
        }
    }

    public nonisolated static let restartReason = "Pincer: Restart Gateway"
    public nonisolated static let refreshInterval: Duration = .seconds(30)
    public nonisolated static let adminRequiredMessage = "Restarting needs Full Management access."

    public private(set) var health: GatewayHealthSummary?
    public private(set) var heartbeat: GatewayHeartbeat?
    /// `last-heartbeat` answered, so a nil heartbeat means "No heartbeat yet".
    public private(set) var heartbeatLoaded = false
    public private(set) var presence: [GatewayPresenceEntry] = []
    public private(set) var serverVersion: String?
    /// `snapshot.uptimeMs` from the last hello, and when it arrived.
    public private(set) var uptimeMs: Int?
    public private(set) var uptimeAnchor: Date?
    public private(set) var connection: ConnectionState = .idle
    public private(set) var unavailable: Set<Section> = []
    /// The `health` call failed with UNAVAILABLE.
    public private(set) var healthFailure: String?
    public private(set) var loadState = OperationState.idle
    public private(set) var hasLoaded = false
    public private(set) var restartState = RestartState.idle
    /// A config or plugin change that only takes effect after a restart.
    public private(set) var restartRequiredReason: String?
    /// When the restart-required flag was set, to clear it once the Gateway process is newer.
    private var restartRequiredAt: Date?
    /// How long after the Gateway went away "hasn't come back yet" shows. Checks lower it.
    public var notBackAfter: Duration = .seconds(60)
    /// Called once the Gateway is back after a restart, e.g. to reload settings.
    @ObservationIgnored public var onRestarted: (@MainActor () -> Void)?
    public let localDeviceId: String?
    /// The demo: Restart is simulated on the device, so it's offered without Full Management.
    public private(set) var simulatedRestart = false
    public let localInstanceId: String?
    /// Dismissed issues by id (`pincer.healthDismissals`, see `GatewayHealthDismissal`). The store keeps
    /// it in sync with the gateway's user prefs.
    public internal(set) var dismissals: [String: String] = [:]
    /// Dismissals this model changed (nil removes one), for the store to save and sync.
    @ObservationIgnored public var onDismissalsChanged: (@MainActor ([String: String?]) -> Void)?

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let hello: @MainActor () -> GatewayHello?
    @ObservationIgnored private var scopesOverride: (@MainActor () -> [String])?
    @ObservationIgnored private var methodsOverride: (@MainActor () -> Set<String>?)?
    @ObservationIgnored private var restartTimer: Task<Void, Never>?
    @ObservationIgnored private var notBackTimer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, localDeviceId: String?,
         simulatedRestart: Bool = false) {
        self.simulatedRestart = simulatedRestart
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.hello = hello
        self.localDeviceId = localDeviceId
        self.localInstanceId = GatewayConnection.instanceId
    }

    /// For checks and previews: `methods` is the Gateway's advertised list (nil or empty when unknown),
    /// `scopes` the granted scopes, and `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [] },
                localDeviceId: String? = nil, localInstanceId: String? = nil,
                dismissals: [String: String] = [:],
                request: @escaping Request)
    {
        self.request = request
        self.dismissals = dismissals
        self.hello = { nil }
        self.methodsOverride = methods
        self.scopesOverride = scopes
        self.localDeviceId = localDeviceId
        self.localInstanceId = localInstanceId
        self.connection = .connected
    }

    private var methods: Set<String>? { self.methodsOverride?() ?? self.hello()?.methods }
    private var scopes: [String] { self.scopesOverride?() ?? self.hello()?.scopes ?? [] }

    // MARK: Derived

    public var issues: [GatewayHealthIssue] { self.issues(now: Date()) }

    public func issues(now: Date) -> [GatewayHealthIssue] {
        guard self.connection == .connected else { return [] }
        return GatewayHealthRules.issues(health: self.health, heartbeat: self.heartbeat, now: now)
    }

    /// Reported issues that aren't dismissed. These are what make the Gateway Degraded.
    public var activeIssues: [GatewayHealthIssue] { self.activeIssues(now: Date()) }

    public func activeIssues(now: Date) -> [GatewayHealthIssue] {
        self.issues(now: now).filter { !self.isDismissed($0) }
    }

    /// Reported issues that are dismissed or always ignored.
    public var dismissedIssues: [GatewayHealthIssue] { self.dismissedIssues(now: Date()) }

    public func dismissedIssues(now: Date) -> [GatewayHealthIssue] {
        self.issues(now: now).filter { self.isDismissed($0) }
    }

    /// Always-ignored issues the connected Gateway isn't reporting right now, as placeholder rows.
    public var ignoredButAbsent: [GatewayHealthIssue] { self.ignoredButAbsent(now: Date()) }

    public func ignoredButAbsent(now: Date) -> [GatewayHealthIssue] {
        guard self.connection == .connected else { return [] }
        let reported = Set(self.issues(now: now).map(\.id))
        return self.dismissals
            .filter { GatewayHealthRules.isAlways(id: $0.key, stored: $0.value) && !reported.contains($0.key) }
            .keys.sorted().map(GatewayHealthIssue.placeholder)
    }

    public func dismissal(for id: String) -> GatewayHealthDismissal? {
        self.dismissals[id].flatMap(GatewayHealthDismissal.init(stored:))
    }

    public func isDismissed(_ issue: GatewayHealthIssue) -> Bool {
        GatewayHealthRules.isDismissed(issue, by: self.dismissal(for: issue.id))
    }

    /// Hides an issue until it changes, or for good (`always`, channels and plugins only).
    public func dismiss(_ issue: GatewayHealthIssue, always: Bool = false) {
        let value: GatewayHealthDismissal = always && issue.canAlwaysIgnore ? .always : .untilChanged(issue.fingerprint)
        self.setDismissals([issue.id: value.stored])
    }

    /// Shows a dismissed issue again.
    public func restore(id: String) {
        guard self.dismissals[id] != nil else { return }
        self.setDismissals([id: nil])
    }

    private func setDismissals(_ changes: [String: String?]) {
        guard !changes.isEmpty else { return }
        for (id, value) in changes { self.dismissals[id] = value }
        self.onDismissalsChanged?(changes)
    }

    /// A fresh result for `source` came in: forget until-changed dismissals it no longer reports.
    private func prune(_ source: GatewayHealthRules.Source) {
        guard self.connection == .connected, !self.dismissals.isEmpty else { return }
        let current = GatewayHealthRules.issues(health: self.health, heartbeat: self.heartbeat, now: Date())
        var kept = GatewayHealthRules.pruned(self.dismissals, current: current, source: source)
        // "Late" needs the heartbeat interval from `health`; a heartbeat that lands first can't judge it.
        if source == .heartbeat, self.health == nil, let late = self.dismissals["heartbeat:late"] {
            kept["heartbeat:late"] = late
        }
        let removed = self.dismissals.keys.filter { kept[$0] == nil }
        self.setDismissals(Dictionary(uniqueKeysWithValues: removed.map { ($0, String?.none) }))
    }

    public var level: GatewayHealthLevel { self.level(now: Date()) }

    public func level(now: Date) -> GatewayHealthLevel {
        GatewayHealthRules.level(connection: self.connection, restarting: self.restartState.isInProgress,
                                 healthUnavailable: self.healthFailure != nil, issueCount: self.activeIssues(now: now).count)
    }

    /// When the Gateway process started, from the hello's uptime.
    public var startedAt: Date? {
        guard let uptimeMs, let uptimeAnchor else { return nil }
        return uptimeAnchor.addingTimeInterval(-Double(uptimeMs) / 1000)
    }

    public func uptime(now: Date = Date()) -> TimeInterval? {
        self.startedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// A saved change waits for a restart, or a channel account says it's pending one.
    public var needsRestart: Bool { self.restartRequiredReason != nil || self.health?.restartPending == true }

    /// Full Management, or the demo, whose restart is simulated and needs no admin scope.
    public var hasAdmin: Bool { self.simulatedRestart || self.scopes.contains(GatewayConnection.adminScope) }

    public func isAvailable(_ section: Section) -> Bool {
        if self.unavailable.contains(section) { return false }
        if let methods = self.methods, !methods.isEmpty, !methods.contains(section.method) { return false }
        return true
    }

    /// Restart can be pressed: admin, the method exists, connected, and nothing already in flight.
    public var canRestart: Bool {
        self.hasAdmin && self.isAvailable(.restart) && self.connection == .connected && !self.restartState.isInProgress
    }

    /// Deferred: offer "Restart Now Anyway".
    public var canForceRestart: Bool {
        if case .waiting = self.restartState { return self.hasAdmin && self.connection == .connected }
        return false
    }

    public var indicator: Indicator? {
        switch self.restartState {
        case .requesting, .waiting, .scheduled, .restarting: return .restarting
        case .reconnecting: return .reconnecting
        case .notBack: return .notBack
        default: break
        }
        guard self.connection == .connected else { return nil }
        if self.needsRestart { return .restartNeeded }
        let count = self.activeIssues.count
        return count > 0 ? .degraded(issues: count) : nil
    }

    /// Clients other than this device first, newest activity first.
    public var sortedPresence: [GatewayPresenceEntry] {
        self.presence.sorted { lhs, rhs in
            let lhsSelf = self.isThisDevice(lhs), rhsSelf = self.isThisDevice(rhs)
            if lhsSelf != rhsSelf { return lhsSelf }
            return (lhs.lastActivityAt ?? lhs.seenAt ?? .distantPast) > (rhs.lastActivityAt ?? rhs.seenAt ?? .distantPast)
        }
    }

    public func isThisDevice(_ entry: GatewayPresenceEntry) -> Bool {
        entry.isThisDevice(deviceId: self.localDeviceId, instanceId: self.localInstanceId)
    }

    // MARK: Connection

    /// Every connection state change; `hello` comes with `.connected`.
    public func connectionChanged(_ state: ConnectionState, hello: GatewayHello?) {
        self.connection = state
        if state == .connected {
            if let hello { self.seed(hello: hello) }
            self.notBackTimer?.cancel()
            self.restartTimer?.cancel()
            switch self.restartState {
            case .restarting, .reconnecting, .notBack, .scheduled, .waiting:
                self.restartState = .restarted(uptimeMs: self.uptimeMs)
                self.clearRestartRequired()
                self.onRestarted?()
                Task { await self.load() }
            case .requesting:
                // The request's socket went away before it answered; this is a fresh connection.
                self.restartState = .idle
            default:
                break
            }
            return
        }
        self.healthFailure = nil
        switch self.restartState {
        case .scheduled, .waiting:
            self.beginRestarting(expectedMs: nil)
        case .restarting:
            break
        default:
            break
        }
    }

    /// Takes version, uptime, presence and health from the hello snapshot.
    public func seed(hello: GatewayHello) {
        self.serverVersion = hello.serverVersion
        self.seed(snapshot: hello.snapshot, at: Date())
    }

    public func seed(snapshot: JSONValue?, serverVersion: String? = nil, at date: Date = Date()) {
        if let serverVersion { self.serverVersion = serverVersion }
        guard let snapshot, snapshot.object != nil else {
            self.uptimeMs = nil
            self.uptimeAnchor = nil
            return
        }
        self.uptimeMs = snapshot["uptimeMs"]?.int.flatMap { $0 >= 0 ? $0 : nil }
        self.uptimeAnchor = self.uptimeMs == nil ? nil : date
        // Restarted elsewhere (CLI, another client) since the change was saved: it's applied now.
        if let flagged = self.restartRequiredAt, let started = self.startedAt, started > flagged {
            self.clearRestartRequired()
        }
        if let presence = snapshot["presence"], presence.array != nil {
            self.presence = GatewayPresenceEntry.list(presence)
        }
        if let health = snapshot["health"], let object = health.object, !object.isEmpty {
            self.health = GatewayHealthSummary(health)
            self.prune(.health)
        }
    }

    // MARK: Events

    /// `health`, `heartbeat`, `presence` and `shutdown` events.
    public func handle(event name: String, payload: JSONValue) {
        switch name {
        case "health":
            if let summary = GatewayHealthSummary(payload) {
                self.health = summary
                self.healthFailure = nil
                if payload.object?.isEmpty == false { self.prune(.health) }
            }
        case "heartbeat":
            if let beat = GatewayHeartbeat(payload) {
                self.heartbeat = beat
                self.heartbeatLoaded = true
                self.prune(.heartbeat)
            }
        case "presence":
            if payload.array != nil || payload["presence"]?.array != nil {
                self.presence = GatewayPresenceEntry.list(payload)
            }
        case "shutdown":
            // Without `restartExpectedMs` the Gateway is stopping for good, unless this device asked for the restart.
            if let expected = Self.restartExpectedMs(shutdown: payload) {
                self.beginRestarting(expectedMs: expected)
            } else {
                switch self.restartState {
                case .requesting, .scheduled, .waiting: self.beginRestarting(expectedMs: nil)
                default: break
                }
            }
        default:
            break
        }
    }

    /// `shutdown.restartExpectedMs` when it's a number: the Gateway will be back. Nil means a terminal stop.
    public nonisolated static func restartExpectedMs(shutdown payload: JSONValue) -> Int? {
        guard case let .number(value)? = payload["restartExpectedMs"], value.isFinite, value >= 0 else { return nil }
        return Int(value.rounded())
    }

    private func beginRestarting(expectedMs: Int?) {
        self.restartState = .restarting
        self.restartTimer?.cancel()
        let wait = max(1000, min(expectedMs ?? 1500, 10_000))
        self.restartTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self, self.restartState == .restarting, self.connection != .connected else { return }
            self.restartState = .reconnecting
        }
        self.notBackTimer?.cancel()
        let limit = self.notBackAfter
        self.notBackTimer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.connection != .connected else { return }
            switch self.restartState {
            case .restarting, .reconnecting: self.restartState = .notBack
            default: break
            }
        }
    }

    // MARK: Restart required

    /// A saved change needs a restart to take effect.
    public func markRestartRequired(_ reason: String, at date: Date = Date()) {
        self.restartRequiredReason = reason
        self.restartRequiredAt = date
    }

    public func clearRestartRequired() {
        self.restartRequiredReason = nil
        self.restartRequiredAt = nil
    }

    /// Hides "Gateway restarted" or a failed attempt.
    public func dismissRestartStatus() {
        switch self.restartState {
        case .restarted, .failed: self.restartState = .idle
        default: break
        }
    }

    // MARK: Loading

    /// `health`, `last-heartbeat` and `system-presence`, each on its own.
    public func load() async {
        guard self.connection == .connected else { return }
        self.generation += 1
        let generation = self.generation
        self.loadState = .running
        async let health: Void = self.loadHealth(generation)
        async let heartbeat: Void = self.loadHeartbeat(generation)
        async let presence: Void = self.loadPresence(generation)
        _ = await (health, heartbeat, presence)
        guard generation == self.generation else { return }
        if self.loadState.isRunning { self.loadState = .idle }
        self.hasLoaded = true
    }

    /// The periodic refresh: `health` and `last-heartbeat`.
    public func refresh() async {
        guard self.connection == .connected else { return }
        self.generation += 1
        let generation = self.generation
        async let health: Void = self.loadHealth(generation)
        async let heartbeat: Void = self.loadHeartbeat(generation)
        _ = await (health, heartbeat)
    }

    private func loadHealth(_ generation: Int) async {
        guard let result = await self.call(.health, [:], generation) else { return }
        if let summary = GatewayHealthSummary(result) {
            self.health = summary
            self.healthFailure = nil
            if result.object?.isEmpty == false { self.prune(.health) }
        }
    }

    private func loadHeartbeat(_ generation: Int) async {
        guard let result = await self.call(.heartbeat, [:], generation) else { return }
        self.heartbeat = GatewayHeartbeat(result)
        self.heartbeatLoaded = true
        self.prune(.heartbeat)
    }

    private func loadPresence(_ generation: Int) async {
        guard let result = await self.call(.presence, [:], generation) else { return }
        if result.array != nil || result["presence"]?.array != nil || result["entries"]?.array != nil {
            self.presence = GatewayPresenceEntry.list(result)
        }
    }

    /// Nil when the section is unavailable, the call failed, or a newer load started.
    private func call(_ section: Section, _ params: JSONValue, _ generation: Int) async -> JSONValue? {
        guard self.isAvailable(section) else { return nil }
        do {
            let result = try await self.request(section.method, params)
            guard generation == self.generation else { return nil }
            return result
        } catch {
            guard generation == self.generation else { return nil }
            if Self.isUnavailableMethod(error) {
                self.unavailable.insert(section)
            } else if section == .health, case let GatewayError.rpc(code, message, _) = error, code == "UNAVAILABLE" {
                self.healthFailure = message
            } else if section == .health {
                self.loadState = .failed(Self.message(for: error))
            }
            return nil
        }
    }

    // MARK: Restart

    /// Asks the Gateway to restart once active work drains, or right away with `skipDeferral`.
    public func restart(skipDeferral: Bool = false) async {
        guard self.hasAdmin else {
            self.restartState = .failed(ConfigWriteError.adminRequired.message)
            return
        }
        guard skipDeferral ? self.canForceRestart : self.canRestart else { return }
        self.restartState = .requesting
        var params: [String: JSONValue] = ["reason": .string(Self.restartReason)]
        if skipDeferral { params["skipDeferral"] = true }
        do {
            let result = GatewayRestartResult(try await self.request("gateway.restart.request", .object(params)))
            // `shutdown` or a reconnect may have moved on already.
            guard self.restartState == .requesting else { return }
            switch result.status {
            case .deferred: self.restartState = .waiting(result.waitingMessage)
            // Forcing escalates the pending restart, so it's going now rather than "already scheduled".
            case .coalesced: self.restartState = .scheduled(coalesced: !skipDeferral)
            case .scheduled, .other: self.restartState = .scheduled(coalesced: false)
            }
        } catch {
            guard self.restartState == .requesting else { return }
            if case GatewayError.closed = error {
                // The Gateway went away before answering: that's the restart.
                self.beginRestarting(expectedMs: nil)
                return
            }
            if Self.isMissingScope(error) {
                self.restartState = .failed(ConfigWriteError.adminRequired.message)
            } else if Self.isUnavailableMethod(error) {
                self.unavailable.insert(.restart)
                self.restartState = .failed("Restarting isn't available on this Gateway.")
            } else {
                self.restartState = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: Errors

    static func isMissingScope(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, details) = error else { return false }
        return code == "MISSING_SCOPE" || details?["code"]?.text == "MISSING_SCOPE"
            || message.lowercased().contains("missing scope")
    }

    /// UNKNOWN_METHOD, or FORBIDDEN that isn't about a scope this device could get.
    static func isUnavailableMethod(_ error: Error) -> Bool {
        if GatewayConfigClient.isUnknownMethod(error) { return true }
        guard case let GatewayError.rpc(code, _, _) = error else { return false }
        return code == "FORBIDDEN" && !Self.isMissingScope(error)
    }

    public static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(code, message, _) = error else { return error.localizedDescription }
        if Self.isMissingScope(error) { return ConfigWriteError.adminRequired.message }
        switch code {
        case "RATE_LIMITED": return "The Gateway limits how often it restarts. Try again in a minute."
        case "INVALID_REQUEST": return "The Gateway refused the restart: \(message)"
        default: return message
        }
    }
}
