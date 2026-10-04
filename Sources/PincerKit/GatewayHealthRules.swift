import Foundation
import Observation

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
                if let before = Self.pressureCounts(fingerprint), let current = Self.pressureCounts(issue.fingerprint) {
                    return zip(current, before).allSatisfy { $0.0 <= $0.1 }
                }
                guard let dismissed = Self.count(fingerprint), let current = Self.count(issue.fingerprint) else {
                    return fingerprint == issue.fingerprint
                }
                return current <= dismissed
            }
            return fingerprint == issue.fingerprint
        }
    }

    private static func pressureCounts(_ fingerprint: String) -> [Int]? {
        let fields = fingerprint.split(separator: ";")
        let keys = ["pending=", "claimed=", "blocked="]
        guard fields.count == keys.count else { return nil }
        var result: [Int] = []
        for (field, key) in zip(fields, keys) {
            guard field.hasPrefix(key), let value = Int(field.dropFirst(key.count)) else { return nil }
            result.append(value)
        }
        return result
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
            for failure in health.ingressFailures {
                issues.append(.init(id: "queue:ingress-failed:\(failure.channelId):\(failure.accountId)", kind: .delivery,
                                    title: L("Incoming messages failed"),
                                    detail: "\(failure.channelId) (\(failure.accountId)): \(failure.count)",
                                    fingerprint: "count=\(failure.count)"))
            }
            for pressure in health.ingressPressure {
                issues.append(.init(id: "queue:ingress-pressure:\(pressure.channelId):\(pressure.accountId)", kind: .delivery,
                                    title: L("Incoming messages are waiting"),
                                    detail: "\(pressure.channelId) (\(pressure.accountId)): "
                                        + L("\(pressure.pendingCount) pending, \(pressure.claimedCount) claimed, \(pressure.blockedCount) blocked"),
                                    fingerprint: "pending=\(pressure.pendingCount);claimed=\(pressure.claimedCount);blocked=\(pressure.blockedCount)"))
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
