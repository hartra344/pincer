import Foundation
import Observation

// MARK: Keys and states

/// One channel account: the channel id and its account id (`default` when the Gateway omits it).
public struct ChannelAccountKey: Hashable, Sendable, Identifiable, Codable {
    public let channel: String
    public let accountId: String

    public init(channel: String, accountId: String?) {
        self.channel = channel
        self.accountId = accountId ?? "default"
    }

    public var id: String { "\(self.channel)/\(self.accountId)" }

    /// From a Gateway Health issue id, `channel:<channel>:<accountId>`; nil for other issues.
    public init?(healthIssueId id: String) {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "channel", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.init(channel: parts[1], accountId: parts[2])
    }
}

/// What a channel account's badge says on Channel Status.
public enum ChannelAccountState: String, Hashable, Sendable, CaseIterable {
    case connected
    case running
    case degraded
    case disconnected
    case loggedOut
    case stopped
    case notConfigured
    case disabled
    case unknown

    public var label: String {
        switch self {
        case .connected: "Connected"
        case .running: "Running"
        case .degraded: "Degraded"
        case .disconnected: "Disconnected"
        case .loggedOut: "Logged Out"
        case .stopped: "Stopped"
        case .notConfigured: "Not Configured"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }

    public var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .running: "play.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .disconnected: "bolt.horizontal.circle"
        case .loggedOut: "person.crop.circle.badge.xmark"
        case .stopped: "stop.circle"
        case .notConfigured: "gearshape"
        case .disabled: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    public var isHealthy: Bool { self == .connected || self == .running }

    /// Something the user may want to fix (not healthy, and not switched off or not set up).
    public var needsAttention: Bool { self == .degraded || self == .disconnected || self == .stopped || self == .loggedOut }
}

/// How Channel Status reads `channels.status` and what it offers. Pure, for tests.
public enum ChannelRules {
    /// Channels whose plugin implements QR login (`loginWithQrStart`) upstream.
    public static let qrLoginChannels: Set<String> = ["whatsapp", "zalouser"]

    public static func supportsQRLogin(_ channelId: String) -> Bool { self.qrLoginChannels.contains(channelId) }

    /// `healthState` values upstream's channel health policy reports for an unhealthy account.
    public static let unhealthyHealthStates: Set<String> = [
        "not-running", "terminal-disconnect", "blocked", "busy", "stuck", "disconnected", "stale-socket",
        "ingress-unavailable",
    ]

    /// Disabled, logged out, not configured and stopped come first; then a last error makes it degraded,
    /// not connected makes it disconnected, and an unhealthy `healthState`, a failed probe or a status
    /// issue make it degraded; else connected or running.
    public static func state(of account: GatewayChannelAccountHealth,
                             issues: [ChannelsStatusSnapshot.Issue] = []) -> ChannelAccountState {
        if account.enabled == false { return .disabled }
        if account.linked == false { return .loggedOut }
        if account.configured == false { return .notConfigured }
        if account.running == false { return .stopped }
        if account.lastError?.isEmpty == false { return .degraded }
        if account.connected == false { return .disconnected }
        let unhealthy = account.healthState.map { self.unhealthyHealthStates.contains($0) } ?? false
        if unhealthy || account.probeOk == false || !issues.isEmpty { return .degraded }
        if account.connected == true { return .connected }
        if account.running == true { return .running }
        return .unknown
    }

    /// One state for a whole channel (Gateway Health's channel list): the most pressing account's.
    public static func summaryState(of channel: GatewayChannelHealth,
                                    issues: [ChannelsStatusSnapshot.Issue] = []) -> ChannelAccountState {
        let states = Set(channel.effectiveAccounts.map { account in
            self.state(of: account, issues: issues.filter { $0.channel == channel.id && $0.accountId == account.accountId })
        })
        let order: [ChannelAccountState] = [.degraded, .disconnected, .loggedOut, .stopped, .notConfigured,
                                            .connected, .running, .unknown, .disabled]
        return order.first(where: states.contains) ?? .unknown
    }

    /// Whether `action` makes sense for an account in `state`.
    public static func offers(_ action: ChannelsModel.Action, state: ChannelAccountState,
                              account: GatewayChannelAccountHealth?) -> Bool {
        switch action {
        case .start:
            return state == .stopped || (state == .unknown && account?.running != true)
        case .stop:
            return account?.running == true
        case .reconnect:
            return [.connected, .running, .degraded, .disconnected, .unknown].contains(state)
        case .logout:
            return state != .notConfigured && state != .loggedOut
        }
    }

    /// An RPC error as the page shows it.
    @MainActor public static func errorText(_ error: Error) -> String {
        GatewayError.message(for: error, scope: SetupWizardModel.fullManagementMessage, unavailable: L("channel status"))
    }

    /// The action the Gateway said a channel doesn't support ("does not support logout/start"), if any.
    public static func unsupportedAction(in error: Error) -> ChannelsModel.Action? {
        guard case let GatewayError.rpc(_, message, _) = error else { return nil }
        let lower = message.lowercased()
        if lower.contains("does not support logout") { return .logout }
        if lower.contains("does not support start") || lower.contains("does not support runtime start") { return .start }
        return nil
    }

    /// A lifecycle failure, with friendlier copy for what upstream reports as unsupported.
    @MainActor public static func message(for error: Error, action: ChannelsModel.Action, channelLabel: String) -> String {
        if GatewayError.isMissingScope(error) { return SetupWizardModel.fullManagementMessage }
        if GatewayError.isUnknownMethod(error) { return L("This Gateway can't \(action.verb) channels.") }
        guard case let GatewayError.rpc(_, message, _) = error else { return error.localizedDescription }
        let lower = message.lowercased()
        if lower.contains("does not support logout") { return L("\(channelLabel) doesn't support logging out.") }
        if lower.contains("does not support start") || lower.contains("does not support runtime start") {
            return L("\(channelLabel) can't be started from Pincer.")
        }
        if lower.contains("config invalid") { return L("The Gateway's config is invalid. Fix it before logging out.") }
        return message
    }

    /// Why `channels.start` didn't hand the account off (`outcome.status` `skipped` / `retry`), or nil.
    public static func startProblem(_ result: JSONValue, channelLabel: String) -> String? {
        let outcome = result["outcome"]
        switch outcome?["status"]?.text {
        case "retry":
            return L("\(channelLabel) is still stopping. Try again in a moment.")
        case "skipped":
            let reason: String = switch outcome?["reason"]?.text {
            case "disabled": L("the account is disabled")
            case "unconfigured": L("the account isn't configured")
            case "unlinked": L("the account isn't linked. Log in first")
            case "secret-unavailable": L("its credentials aren't available")
            case "unsupported": L("the channel doesn't support starting")
            case let other?: ApprovalRecord.humanized(other).lowercased()
            case nil: L("the Gateway skipped it")
            }
            return L("\(channelLabel) didn't start: \(reason).")
        default:
            return nil
        }
    }
}

// MARK: Snapshot

/// `channels.status` (operator.read): channels with their account snapshots, plus the Gateway's
/// own status issues. Channels are `GatewayChannelHealth`, the same type Gateway Health shows.
public struct ChannelsStatusSnapshot: Hashable, Sendable {
    public struct Issue: Hashable, Sendable {
        public let channel: String
        public let accountId: String
        public let kind: String
        public let message: String
        public let fix: String?

        public var key: ChannelAccountKey { ChannelAccountKey(channel: self.channel, accountId: self.accountId) }
    }

    public let channels: [GatewayChannelHealth]
    public let issues: [Issue]
    /// `ts`.
    public let checkedAt: Date?
    public let defaultAccountIds: [String: String]
    public let detailLabels: [String: String]
    /// Some channel or probe timed out or failed; `warnings` says which.
    public let partial: Bool
    public let warnings: [String]

    public init(channels: [GatewayChannelHealth], issues: [Issue] = []) {
        self.channels = channels
        self.issues = issues
        self.checkedAt = nil
        self.defaultAccountIds = [:]
        self.detailLabels = [:]
        self.partial = false
        self.warnings = []
    }

    /// Parses a `channels.status` result: `channelOrder`, `channelLabels`, `channelAccounts`
    /// (`{ <channel>: [accountSnapshot] }`), `channels` (per-channel summaries) and `statusIssues`.
    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        let labels = json["channelLabels"]?.object ?? [:]
        let summaries = json["channels"]?.object ?? [:]
        let accounts = json["channelAccounts"]?.object ?? [:]
        let order = (json["channelOrder"]?.array ?? []).compactMap(\.text)
        var seen: Set<String> = []
        let ids = (order + accounts.keys.sorted() + summaries.keys.sorted()).filter { seen.insert($0).inserted }
        self.channels = ids.map { id in
            var entry = summaries[id]?.object ?? [:]
            var byId: [String: JSONValue] = [:]
            for account in accounts[id]?.array ?? [] {
                guard let accountId = account["accountId"]?.text else { continue }
                byId[accountId] = account
            }
            if !byId.isEmpty { entry["accounts"] = .object(byId) }
            return GatewayChannelHealth(id: id, label: labels[id]?.text, .object(entry))
        }
        self.issues = (json["statusIssues"]?.array ?? []).compactMap { issue in
            guard let channel = issue["channel"]?.text, let message = issue["message"]?.text else { return nil }
            return Issue(channel: channel, accountId: issue["accountId"]?.text ?? "default",
                         kind: issue["kind"]?.text ?? "runtime", message: message, fix: issue["fix"]?.text)
        }
        self.checkedAt = json["ts"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.defaultAccountIds = (json["channelDefaultAccountId"]?.object ?? [:]).compactMapValues(\.text)
        self.detailLabels = (json["channelDetailLabels"]?.object ?? [:]).compactMapValues(\.text)
        self.partial = json["partial"]?.bool == true
        self.warnings = (json["warnings"]?.array ?? []).compactMap(\.text)
    }

    /// From the `health` payload, when `channels.status` isn't available.
    public init(health: GatewayHealthSummary) {
        self.init(channels: health.channels)
    }

    public func channel(_ id: String) -> GatewayChannelHealth? { self.channels.first { $0.id == id } }

    public func account(_ key: ChannelAccountKey) -> GatewayChannelAccountHealth? {
        self.channel(key.channel)?.effectiveAccounts.first { $0.accountId == key.accountId }
    }

    public func issues(for key: ChannelAccountKey) -> [Issue] { self.issues.filter { $0.key == key } }

    public func state(of key: ChannelAccountKey) -> ChannelAccountState? {
        self.account(key).map { ChannelRules.state(of: $0, issues: self.issues(for: key)) }
    }
}

public typealias SetupChannelsSnapshot = ChannelsStatusSnapshot

// MARK: Model

/// Channel Status for one Gateway: every channel account's state from `channels.status` (operator.read),
/// and start, stop, log out, reconnect and QR login (operator.admin). There's no channel status
/// event upstream, so the page loads on open, polls while showing and reloads after each action.
@MainActor
@Observable
public final class ChannelsModel {
    public enum Action: String, Hashable, Sendable, CaseIterable {
        case start
        case stop
        case logout
        /// `channels.stop`, then `channels.start`.
        case reconnect

        public var title: String {
            switch self {
            case .start: "Start"
            case .stop: "Stop"
            case .logout: "Log Out"
            case .reconnect: "Reconnect"
            }
        }

        public var symbol: String {
            switch self {
            case .start: "play.fill"
            case .stop: "stop.fill"
            case .logout: "rectangle.portrait.and.arrow.right"
            case .reconnect: "arrow.triangle.2.circlepath"
            }
        }

        var verb: String {
            switch self {
            case .start: "start"
            case .stop: "stop"
            case .logout: "log out"
            case .reconnect: "reconnect"
            }
        }

        /// The RPC, or nil for reconnect (stop then start).
        public var method: String? {
            switch self {
            case .start: ChannelsModel.startMethod
            case .stop: ChannelsModel.stopMethod
            case .logout: ChannelsModel.logoutMethod
            case .reconnect: nil
            }
        }
    }

    public struct Operation: Equatable, Sendable {
        public let action: Action
        public let state: OperationState
    }

    public struct Notice: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
        public let isError: Bool
    }

    public nonisolated static let statusMethod = "channels.status"
    public nonisolated static let startMethod = "channels.start"
    public nonisolated static let stopMethod = "channels.stop"
    public nonisolated static let logoutMethod = "channels.logout"
    public nonisolated static let refreshInterval: Duration = .seconds(30)
    public nonisolated static let probeTimeoutMs = 10000

    public private(set) var snapshot: ChannelsStatusSnapshot?
    public private(set) var loadState = OperationState.idle
    public private(set) var isProbing = false
    public private(set) var hasLoaded = false
    /// In flight or failed, by account.
    public private(set) var operations: [ChannelAccountKey: Operation] = [:]
    /// A one-off message for the page ("Reconnected Telegram").
    public private(set) var notice: Notice?
    /// "Show in Channel Status" from Health: the page scrolls to it, then clears it.
    public var focusedAccount: ChannelAccountKey?
    public let qr: ChannelQRLoginController
    /// Actions the Gateway said a channel doesn't support, by "<channel>:<action>". Hidden afterwards.
    public private(set) var unsupported: Set<String> = []
    /// The page is on screen, so `health` events refresh it.
    @ObservationIgnored public var isShowing = false
    @ObservationIgnored private var loadedAt: Date?
    /// After a lifecycle action or QR login succeeds, e.g. to refresh Gateway Health.
    @ObservationIgnored public var onChanged: (@MainActor () async -> Void)?

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored var methods: @MainActor () -> Set<String>?
    @ObservationIgnored var scopes: @MainActor () -> [String]
    /// Gateway Health's channels, for labels before `channels.status` has loaded.
    @ObservationIgnored var fallbackChannels: @MainActor () -> [GatewayChannelHealth] = { [] }
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private var generation = 0
    private var unknownMethod = false

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool) {
        let request: Request = { method, params in try await connection.request(method, params, timeout: 150) }
        self.request = request
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.qr = ChannelQRLoginController(request: request)
        self.qr.onLinked = { [weak self] _ in await self?.didChange() }
    }

    /// For checks and previews: `methods` is the Gateway's advertised method list (nil or empty
    /// when unknown), `scopes` the scopes it granted, `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [] },
                allowsWritesWithoutAdmin: Bool = false,
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.qr = ChannelQRLoginController(request: request)
        self.qr.onLinked = { [weak self] _ in await self?.didChange() }
    }

    // MARK: State

    private func isAdvertised(_ method: String) -> Bool {
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    /// False when the Gateway has no `channels.status`.
    public var supported: Bool { !self.unknownMethod && self.isAdvertised(Self.statusMethod) }

    /// Start, stop, log out, reconnect and QR login need Full Management (`operator.admin`).
    public var canManage: Bool {
        self.allowsWritesWithoutAdmin || self.scopes().contains(GatewayConnection.adminScope)
    }

    /// The Gateway has the methods behind `action` (web login isn't advertised, so it's assumed).
    public func supports(_ action: Action) -> Bool {
        switch action {
        case .reconnect: self.isAdvertised(Self.startMethod) && self.isAdvertised(Self.stopMethod)
        default: self.isAdvertised(action.method ?? "")
        }
    }

    public func account(_ key: ChannelAccountKey) -> GatewayChannelAccountHealth? { self.snapshot?.account(key) }

    public func state(of key: ChannelAccountKey) -> ChannelAccountState { self.snapshot?.state(of: key) ?? .unknown }

    public func operation(for key: ChannelAccountKey) -> Operation? { self.operations[key] }

    public func isBusy(_ key: ChannelAccountKey) -> Bool {
        self.operations[key]?.state.isRunning == true
            || self.qr.state(channel: key.channel, accountId: key.accountId).isRunning
    }

    /// Whether the account's actions list `action` at all (it may still be locked by `canManage`).
    public func offers(_ action: Action, on key: ChannelAccountKey) -> Bool {
        self.supports(action) && !self.isUnsupported(action, channel: key.channel)
            && ChannelRules.offers(action, state: self.state(of: key), account: self.account(key))
    }

    /// The Gateway already said this channel can't do `action` (reconnect needs start).
    public func isUnsupported(_ action: Action, channel: String) -> Bool {
        let needed: Action = action == .reconnect ? .start : action
        return self.unsupported.contains("\(channel):\(needed.rawValue)")
    }

    /// Offered, allowed and nothing else running on the account.
    public func canPerform(_ action: Action, on key: ChannelAccountKey) -> Bool {
        self.canManage && self.offers(action, on: key) && !self.isBusy(key)
    }

    /// QR login is offered on channels that support it; it needs Full Management.
    public func offersQRLogin(_ key: ChannelAccountKey) -> Bool {
        ChannelRules.supportsQRLogin(key.channel) && self.state(of: key) != .disabled
    }

    public func canLogIn(_ key: ChannelAccountKey) -> Bool { self.canManage && self.offersQRLogin(key) }

    /// Accounts with a problem, for the sidebar.
    public var attentionCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.channels.reduce(0) { total, channel in
            total + channel.effectiveAccounts.count { account in
                ChannelRules.state(of: account, issues: snapshot.issues(for: .init(channel: channel.id, accountId: account.accountId)))
                    .needsAttention
            }
        }
    }

    public func label(for key: ChannelAccountKey) -> String {
        let channel = self.snapshot?.channel(key.channel) ?? self.fallbackChannels().first { $0.id == key.channel }
        let label = channel?.label ?? ApprovalRecord.humanized(key.channel)
        guard let channel, channel.effectiveAccounts.count > 1 || key.accountId != "default" else { return label }
        let name = channel.effectiveAccounts.first { $0.accountId == key.accountId }?.name ?? key.accountId
        return "\(label) (\(name))"
    }

    public func clearNotice() { self.notice = nil }

    // MARK: Loading

    /// `channels.status` without probing.
    public func load() async {
        await self.fetch(probe: false)
    }

    public func refresh() async { await self.load() }

    /// A periodic refresh: skipped while a load or probe is running.
    public func poll() async {
        guard !self.loadState.isRunning, !self.isProbing else { return }
        await self.load()
    }

    /// `channels.status` with `probe: true`: each configured account checks its connection.
    public func probe() async {
        await self.fetch(probe: true)
    }

    private func fetch(probe: Bool) async {
        guard self.supported else {
            self.hasLoaded = true
            return
        }
        self.generation += 1
        let generation = self.generation
        self.loadState = .running
        if probe { self.isProbing = true }
        defer { if generation == self.generation { self.isProbing = false } }
        var params: [String: JSONValue] = ["probe": .bool(probe)]
        if probe { params["timeoutMs"] = .number(Double(Self.probeTimeoutMs)) }
        do {
            let result = try await self.request(Self.statusMethod, .object(params))
            guard generation == self.generation else { return }
            if let snapshot = ChannelsStatusSnapshot(result) {
                self.snapshot = snapshot
                self.loadState = .idle
                self.loadedAt = Date()
            } else {
                self.loadState = .failed("The Gateway sent an unexpected channel status.")
            }
        } catch let error where GatewayError.isUnknownMethod(error) {
            guard generation == self.generation else { return }
            self.unknownMethod = true
            self.snapshot = nil
            self.loadState = .idle
        } catch {
            guard generation == self.generation else { return }
            self.loadState = .failed(ChannelRules.errorText(error))
        }
        self.hasLoaded = true
    }

    /// A `health` event: things changed on the Gateway, so reload while the page is showing
    /// (at most every few seconds; there's no channel status event).
    public func healthDidChange() {
        guard self.isShowing, self.hasLoaded, self.supported, !self.loadState.isRunning, !self.isProbing else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.healthRefreshSpacing { return }
        Task { await self.load() }
    }

    nonisolated static let healthRefreshSpacing: TimeInterval = 5

    /// The connection dropped: keep the last-known list (shown dimmed), stop anything in flight.
    public func disconnected() {
        guard self.loadState != .idle || self.isProbing || !self.operations.isEmpty || !self.qr.logins.isEmpty else { return }
        self.generation += 1
        self.loadState = .idle
        self.isProbing = false
        self.operations = [:]
        self.qr.reset()
    }

    /// Forgets everything.
    public func reset() {
        guard self.hasLoaded || self.snapshot != nil || !self.operations.isEmpty || !self.qr.logins.isEmpty
            || self.loadState != .idle else { return }
        self.generation += 1
        self.snapshot = nil
        self.loadState = .idle
        self.isProbing = false
        self.hasLoaded = false
        self.operations = [:]
        self.unknownMethod = false
        self.unsupported = []
        self.loadedAt = nil
        self.qr.reset()
    }

    // MARK: Actions

    @discardableResult public func start(_ key: ChannelAccountKey) async -> Bool { await self.perform(.start, on: key) }
    @discardableResult public func stop(_ key: ChannelAccountKey) async -> Bool { await self.perform(.stop, on: key) }
    @discardableResult public func logout(_ key: ChannelAccountKey) async -> Bool { await self.perform(.logout, on: key) }
    @discardableResult public func reconnect(_ key: ChannelAccountKey) async -> Bool { await self.perform(.reconnect, on: key) }

    /// Runs `action` on one account, then reloads status and tells `onChanged`. False when it failed
    /// (the error is in `operation(for:)` and the notice) or wasn't allowed.
    @discardableResult
    public func perform(_ action: Action, on key: ChannelAccountKey) async -> Bool {
        guard self.canManage else {
            self.fail(action, key, SetupWizardModel.fullManagementMessage)
            return false
        }
        guard self.operations[key]?.state.isRunning != true else { return false }
        let label = self.label(for: key)
        self.operations[key] = Operation(action: action, state: .running)
        let params: JSONValue = ["channel": .string(key.channel), "accountId": .string(key.accountId)]
        do {
            var problem: String?
            switch action {
            case .start:
                problem = ChannelRules.startProblem(try await self.request(Self.startMethod, params), channelLabel: label)
            case .stop:
                let result = try await self.request(Self.stopMethod, params)
                if result["stopped"]?.bool == false { problem = "\(label) is still stopping." }
            case .logout:
                let result = try await self.request(Self.logoutMethod, params)
                if result["cleared"]?.bool == false, result["loggedOut"]?.bool != true {
                    problem = "\(label) had no saved login to clear."
                }
            case .reconnect:
                _ = try await self.request(Self.stopMethod, params)
                problem = ChannelRules.startProblem(try await self.request(Self.startMethod, params), channelLabel: label)
            }
            if let problem {
                self.fail(action, key, problem)
            } else {
                self.operations[key] = nil
                self.notice = Notice(text: Self.doneText(action, label: label), isError: false)
            }
            await self.didChange()
            return problem == nil
        } catch {
            self.fail(action, key, ChannelRules.message(for: error, action: action, channelLabel: label))
            if let unsupported = ChannelRules.unsupportedAction(in: error) {
                self.unsupported.insert("\(key.channel):\(unsupported.rawValue)")
            }
            await self.load()
            return false
        }
    }

    /// QR login on the Channel Status page; relinks (`force`) an account that's linked.
    public func startQRLogin(_ key: ChannelAccountKey, force: Bool = false) {
        guard self.canLogIn(key) else { return }
        self.qr.start(channel: key.channel, accountId: key.accountId, force: force)
    }

    public func cancelQRLogin(_ key: ChannelAccountKey) {
        self.qr.cancel(channel: key.channel, accountId: key.accountId)
    }

    private func fail(_ action: Action, _ key: ChannelAccountKey, _ message: String) {
        self.operations[key] = Operation(action: action, state: .failed(message))
        self.notice = Notice(text: message, isError: true)
    }

    private func didChange() async {
        await self.load()
        await self.onChanged?()
    }

    static func doneText(_ action: Action, label: String) -> String {
        switch action {
        case .start: "Started \(label)."
        case .stop: "Stopped \(label)."
        case .logout: "Logged out of \(label)."
        case .reconnect: "Reconnected \(label)."
        }
    }
}
