import Foundation
import Observation

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
    /// When the last `health` event arrived; polling is only a fallback for when these go quiet.
    public private(set) var lastHealthEventAt: Date?
    private var lastRefreshAt: Date?
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
    /// Capture the first load's issues as quiet in the sidebar indicator until the Health page is viewed (the demo).
    public var quietsInitialIssues = false
    /// Issue ids the sidebar indicator skips; the Health page, menu bar and Settings still count them.
    public private(set) var quietedIssueIds: Set<String> = []
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
    @ObservationIgnored var hello: @MainActor () -> GatewayHello?
    @ObservationIgnored private var scopesOverride: (@MainActor () -> [String])?
    @ObservationIgnored private var methodsOverride: (@MainActor () -> Set<String>?)?
    @ObservationIgnored private var restartTimer: Task<Void, Never>?
    @ObservationIgnored private var notBackTimer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, localDeviceId: String?,
         simulatedRestart: Bool = false, quietsInitialIssues: Bool = false) {
        self.simulatedRestart = simulatedRestart
        self.quietsInitialIssues = quietsInitialIssues
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
                dismissals: [String: String] = [:], quietsInitialIssues: Bool = false,
                request: @escaping Request)
    {
        self.quietsInitialIssues = quietsInitialIssues
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

    /// A channel account has an issue that isn't dismissed (the Channel Status sidebar mark).
    public var hasChannelAccountIssues: Bool { self.activeIssues.contains { $0.channelAccount != nil } }

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

    /// Applies and reports only the changes that alter `dismissals`; nothing happens when none do.
    private func setDismissals(_ changes: [String: String?]) {
        let effective = changes.filter { self.dismissals[$0.key] != $0.value }
        guard !effective.isEmpty else { return }
        for (id, value) in effective { self.dismissals[id] = value }
        self.onDismissalsChanged?(effective)
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
        let count = self.activeIssues.filter { !self.quietedIssueIds.contains($0.id) }.count
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
            self.quietInitialIssuesIfNeeded()
        }
    }

    // MARK: Events

    /// `health`, `heartbeat`, `presence` and `shutdown` events.
    public func handle(event name: String, payload: JSONValue) {
        switch name {
        case "health":
            if let summary = GatewayHealthSummary(payload) {
                self.health = summary
                self.lastHealthEventAt = Date()
                self.healthFailure = nil
                if payload.object?.isEmpty == false { self.prune(.health) }
                self.quietInitialIssuesIfNeeded()
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
        self.quietInitialIssuesIfNeeded()
        self.hasLoaded = true
    }

    /// The first health the model gets (hello snapshot, event or load) sets the quiet issues, once.
    private func quietInitialIssuesIfNeeded() {
        guard self.quietsInitialIssues, self.health != nil else { return }
        self.quietedIssueIds = Set(self.activeIssues.map(\.id))
        self.quietsInitialIssues = false
    }

    /// The Health page was opened: the sidebar indicator counts every issue again.
    public func markIssuesViewed() {
        self.quietsInitialIssues = false
        self.quietedIssueIds = []
    }

    /// The periodic refresh: `health` and `last-heartbeat`.
    /// Polls only if neither a `health` event nor a refresh landed within `refreshInterval`.
    public func refreshIfStale(now: Date = Date()) async {
        let interval = Double(GatewayHealthModel.refreshInterval.components.seconds)
        let last = [self.lastHealthEventAt, self.lastRefreshAt].compactMap { $0 }.max()
        if let last, now.timeIntervalSince(last) < interval { return }
        await self.refresh()
    }

    public func refresh() async {
        guard self.connection == .connected else { return }
        self.lastRefreshAt = Date()
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
            if GatewayError.isMissingScope(error) {
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

    /// UNKNOWN_METHOD, or FORBIDDEN that isn't about a scope this device could get.
    static func isUnavailableMethod(_ error: Error) -> Bool { GatewayError.isUnavailable(error) }

    public static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(code, message, _) = error else { return error.localizedDescription }
        if GatewayError.isMissingScope(error) { return ConfigWriteError.adminRequired.message }
        switch code {
        case "RATE_LIMITED": return "The Gateway limits how often it restarts. Try again in a minute."
        case "INVALID_REQUEST": return "The Gateway refused the restart: \(message)"
        default: return message
        }
    }
}
