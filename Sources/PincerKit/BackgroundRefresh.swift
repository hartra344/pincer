import Foundation
import UserNotifications

// Local notifications without a push server: iOS wakes the app now and then (BGAppRefreshTask),
// which asks each saved gateway what's new and posts what the live app would have. The
// scheduling lives in the iOS app; everything here is platform-neutral so tests can drive it.

// MARK: Setting

/// What notifies the user while Pincer is closed.
public enum ClosedAppDelivery: String, CaseIterable, Identifiable, Sendable {
    case backgroundRefresh = "refresh"
    case pushRelay = "push"
    case off

    public static let key = "pincer.closedAppDelivery"

    /// The stored choice; unset means push for someone who already set up a relay, else refresh.
    public static func current(_ defaults: UserDefaults = .standard) -> ClosedAppDelivery {
        if let raw = defaults.string(forKey: self.key), let mode = ClosedAppDelivery(rawValue: raw) { return mode }
        return (defaults.string(forKey: "pincer.pushRelay") ?? "").isEmpty ? .backgroundRefresh : .pushRelay
    }

    public static func set(_ mode: ClosedAppDelivery, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: self.key)
    }

    public var id: String { self.rawValue }

    public var label: String {
        switch self {
        case .pushRelay: "Push relay"
        case .backgroundRefresh: "Background refresh"
        case .off: "Off"
        }
    }
}

// MARK: Cursor

/// What a gateway had already told the user about, so a refresh only notifies newer things.
public struct BackgroundRefreshCursor: Codable, Equatable, Sendable {
    public var activityMs: Double
    public var approvalIds: [String]
    public var questionIds: [String]

    public init(activityMs: Double, approvalIds: [String] = [], questionIds: [String] = []) {
        self.activityMs = activityMs
        self.approvalIds = approvalIds
        self.questionIds = questionIds
    }
}

public struct BackgroundRefreshCursorStore: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ gatewayId: UUID) -> String { "pincer.refresh.cursor.\(gatewayId.uuidString)" }

    public func cursor(for gatewayId: UUID) -> BackgroundRefreshCursor? {
        self.defaults.data(forKey: self.key(gatewayId)).flatMap { try? JSONDecoder().decode(BackgroundRefreshCursor.self, from: $0) }
    }

    public func save(_ cursor: BackgroundRefreshCursor, for gatewayId: UUID) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        self.defaults.set(data, forKey: self.key(gatewayId))
    }

    /// Marks something the live app already notified about. Only moves an existing cursor:
    /// without one, the next run baselines anyway.
    public func advance(gatewayId: UUID, activityMs: Double? = nil, approvalId: String? = nil, questionId: String? = nil) {
        guard var cursor = self.cursor(for: gatewayId) else { return }
        if let activityMs { cursor.activityMs = max(cursor.activityMs, activityMs) }
        if let approvalId, !cursor.approvalIds.contains(approvalId) { cursor.approvalIds.append(approvalId) }
        if let questionId, !cursor.questionIds.contains(questionId) { cursor.questionIds.append(questionId) }
        cursor.approvalIds = Array(cursor.approvalIds.suffix(BackgroundRefreshPlanner.maxIds))
        cursor.questionIds = Array(cursor.questionIds.suffix(BackgroundRefreshPlanner.maxIds))
        self.save(cursor, for: gatewayId)
    }

    public func remove(for gatewayId: UUID) {
        self.defaults.removeObject(forKey: self.key(gatewayId))
    }
}

// MARK: Planner

/// Which chats may notify: the sidebar's "hidden chat" rule (#188), plus subagents and archived.
public struct BackgroundRefreshFilter: Equatable, Sendable {
    public var showAutomations: Bool
    public var showSlashCommands: Bool

    public init(showAutomations: Bool = false, showSlashCommands: Bool = false) {
        self.showAutomations = showAutomations
        self.showSlashCommands = showSlashCommands
    }

    public static func load(gatewayId: UUID, defaults: UserDefaults = .standard) -> BackgroundRefreshFilter {
        BackgroundRefreshFilter(
            showAutomations: defaults.bool(forKey: "pincer.showAutomations.\(gatewayId.uuidString)"),
            showSlashCommands: defaults.bool(forKey: "pincer.showSlashCommands.\(gatewayId.uuidString)"))
    }

    public func notifies(_ row: SessionRow) -> Bool {
        guard !row.isSubagent, !row.isArchived else { return false }
        return !((row.isAutomation && !self.showAutomations) || (row.isSlashCommands && !self.showSlashCommands))
    }
}

public struct BackgroundRefreshSnapshot: Sendable {
    public var agents: [AgentSummary]
    public var defaultAgentId: String
    public var sessions: [SessionRow]
    public var approvals: [ExecApproval]
    public var questions: [QuestionPrompt]

    public init(
        agents: [AgentSummary] = [], defaultAgentId: String = "main", sessions: [SessionRow] = [],
        approvals: [ExecApproval] = [], questions: [QuestionPrompt] = [])
    {
        self.agents = agents
        self.defaultAgentId = defaultAgentId
        self.sessions = sessions
        self.approvals = approvals
        self.questions = questions
    }

    func agent(_ id: String) -> AgentSummary {
        self.agents.first { $0.id == id } ?? AgentSummary(id: id, name: id == "main" ? "Main" : id.capitalized)
    }
}

/// Pure: what to post for a gateway and the cursor to save afterwards.
public enum BackgroundRefreshPlanner {
    public static let maxPerGateway = 10
    static let maxIds = 200

    public static func plan(
        snapshot: BackgroundRefreshSnapshot, cursor: BackgroundRefreshCursor?, filter: BackgroundRefreshFilter,
        gatewayId: UUID, gatewayName: String, now: Date = Date()) -> (requests: [UNNotificationRequest], cursor: BackgroundRefreshCursor)
    {
        let next = self.cursor(for: snapshot, now: now, floor: cursor?.activityMs)
        guard let cursor else { return ([], next) }

        var requests: [UNNotificationRequest] = []
        for approval in self.pending(snapshot.approvals, now) where !cursor.approvalIds.contains(approval.id) {
            requests.append(Notifier.approvalRequest(approval, gatewayId: gatewayId, gatewayName: gatewayName))
        }
        for prompt in snapshot.questions where prompt.isAnswerable(at: now) && !cursor.questionIds.contains(prompt.id) {
            let agent = snapshot.agent(
                prompt.agentId ?? prompt.sessionKey.flatMap(SessionKey.agentId(from:)) ?? snapshot.defaultAgentId)
            let chat = prompt.sessionKey.flatMap { key in snapshot.sessions.first { $0.key == key }?.title }
            if let request = Notifier.questionRequest(prompt, gatewayId: gatewayId, agent: agent, chatTitle: chat) {
                requests.append(request)
            }
        }
        let replies = snapshot.sessions
            .filter { $0.activityMs > cursor.activityMs && $0.isUnread && !$0.hasActiveRun && filter.notifies($0) }
            .sorted { $0.activityMs > $1.activityMs }
        return (requests + replies.prefix(self.maxPerGateway).map { row in
            Notifier.replyContent(
                id: "reply:\(row.key):\(Int(row.activityMs))",
                title: Notifier.replyTitle(rowTitle: row.title, agent: snapshot.agent(row.agentId)),
                body: Notifier.clip(row.preview ?? "New activity"),
                target: Notifier.Target(gatewayId: gatewayId, sessionKey: row.key))
        }, next)
    }

    /// The baseline: everything currently there counts as already seen.
    public static func cursor(for snapshot: BackgroundRefreshSnapshot, now: Date = Date()) -> BackgroundRefreshCursor {
        self.cursor(for: snapshot, now: now, floor: nil)
    }

    private static func cursor(for snapshot: BackgroundRefreshSnapshot, now: Date, floor: Double?) -> BackgroundRefreshCursor {
        BackgroundRefreshCursor(
            activityMs: max(floor ?? 0, snapshot.sessions.map(\.activityMs).max() ?? 0),
            approvalIds: Array(self.pending(snapshot.approvals, now).map(\.id).prefix(self.maxIds)),
            questionIds: Array(snapshot.questions.filter { $0.isAnswerable(at: now) }.map(\.id).prefix(self.maxIds)))
    }

    private static func pending(_ approvals: [ExecApproval], _ now: Date) -> [ExecApproval] {
        approvals.filter { !$0.isExpired(at: now) }
    }
}

// MARK: Runner

@MainActor
public final class BackgroundRefresh {
    public static let taskIdentifier = "chat.pincer.refresh"
    public static let defaultBudget: TimeInterval = 25
    public static let interval: TimeInterval = 15 * 60

    public struct Report: Equatable, Sendable {
        public var posted = 0
        /// Gateways that ran out of time or were cancelled.
        public var aborted: [UUID] = []
        /// Gateways that couldn't be reached or answered badly.
        public var failed: [UUID] = []
        public var skipped = false
    }

    private enum Outcome: Sendable {
        case snapshot(BackgroundRefreshSnapshot)
        case failed
    }

    private let profiles: @MainActor () -> [GatewayProfile]
    private let connector: any IntentConnector
    private let cursors: BackgroundRefreshCursorStore
    private let defaults: UserDefaults
    private let post: @MainActor ([UNNotificationRequest]) async -> Void
    private let timer: @Sendable (TimeInterval) async -> Void

    public init(
        profiles: @escaping @MainActor () -> [GatewayProfile] = { GatewayProfileStore.load() },
        connector: any IntentConnector = GatewayIntentConnector(),
        cursors: BackgroundRefreshCursorStore = BackgroundRefreshCursorStore(),
        defaults: UserDefaults = .standard,
        post: @escaping @MainActor ([UNNotificationRequest]) async -> Void = { await Notifier.shared.postBackground($0) },
        /// Waits out the run's budget; tests pass a gate to end it on cue.
        timer: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) })
    {
        self.profiles = profiles
        self.connector = connector
        self.cursors = cursors
        self.defaults = defaults
        self.post = post
        self.timer = timer
    }

    public static var lastRun: Date? { UserDefaults.standard.object(forKey: "pincer.refresh.lastRun") as? Date }
    public static var lastResult: String? { UserDefaults.standard.string(forKey: "pincer.refresh.lastResult") }

    /// Skips unless notifications are on and the mode is background refresh.
    public func run(budget: TimeInterval = defaultBudget) async -> Report {
        var report = Report()
        guard self.defaults.object(forKey: "pincer.notifications") as? Bool ?? true,
              ClosedAppDelivery.current(self.defaults) == .backgroundRefresh
        else {
            report.skipped = true
            return report
        }
        let deadline = Date().addingTimeInterval(budget)
        let profiles = self.profiles().filter { !$0.isDemo }
        let connector = self.connector
        let timer = self.timer
        let fetches = profiles.map { profile in
            Task { @MainActor () -> Outcome? in
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                return await Self.bounded(seconds: remaining, timer: timer) {
                    await Self.fetch(profile, connector: connector, timeout: remaining)
                }
            }
        }
        var outcomes: [UUID: Outcome?] = [:]
        await withTaskCancellationHandler {
            for (profile, fetch) in zip(profiles, fetches) { outcomes[profile.id] = await fetch.value }
        } onCancel: {
            for fetch in fetches { fetch.cancel() }
        }
        for profile in profiles {
            guard !Task.isCancelled, let outcome = outcomes[profile.id] ?? nil else {
                report.aborted.append(profile.id)
                continue
            }
            guard case let .snapshot(snapshot) = outcome else {
                report.failed.append(profile.id)
                continue
            }
            let plan = BackgroundRefreshPlanner.plan(
                snapshot: snapshot, cursor: self.cursors.cursor(for: profile.id),
                filter: .load(gatewayId: profile.id, defaults: self.defaults),
                gatewayId: profile.id, gatewayName: profile.name)
            if !plan.requests.isEmpty { await self.post(plan.requests) }
            self.cursors.save(plan.cursor, for: profile.id)
            report.posted += plan.requests.count
        }
        let unreached = Set(report.aborted + report.failed)
        let names = profiles.filter { unreached.contains($0.id) }.map(\.name)
        let problem = Task.isCancelled ? "Stopped early" : names.isEmpty ? nil : "Couldn't reach \(names.joined(separator: ", "))"
        let parts = [report.posted > 0 ? "\(report.posted) new" : nil, problem].compactMap { $0 }
        self.defaults.set(Date(), forKey: "pincer.refresh.lastRun")
        self.defaults.set(parts.isEmpty ? "Up to date" : parts.joined(separator: " · "), forKey: "pincer.refresh.lastResult")
        return report
    }

    /// On entering background: what each connected gateway's live state shows is already seen.
    /// A cursor only moves forward, and only over ids still pending.
    public func seed(from gateways: [GatewayStore]) {
        for gateway in gateways where gateway.bootstrapped && gateway.state.isConnected && !gateway.profile.isDemo {
            let live = BackgroundRefreshPlanner.cursor(for: BackgroundRefreshSnapshot(
                sessions: Array(gateway.sessions.values), approvals: gateway.approvals, questions: gateway.questions))
            var cursor = self.cursors.cursor(for: gateway.id) ?? live
            cursor.activityMs = max(cursor.activityMs, live.activityMs)
            cursor.approvalIds = Array(Set(cursor.approvalIds + live.approvalIds).intersection(live.approvalIds))
            cursor.questionIds = Array(Set(cursor.questionIds + live.questionIds).intersection(live.questionIds))
            self.cursors.save(cursor, for: gateway.id)
        }
    }

    /// Agents and chats must load; approvals and questions are optional (older gateways lack them).
    public static func fetch(_ connection: any IntentConnection, timeout: TimeInterval) async throws -> BackgroundRefreshSnapshot {
        let agents = try await connection.request("agents.list", [:], timeout: timeout)
        let sessions = try await connection.request(
            "sessions.list", ["limit": 200, "includeLastMessage": true, "archived": false], timeout: timeout)
        let approvals = try? await connection.request("exec.approval.list", [:], timeout: timeout)
        let questions = try? await connection.request("question.list", [:], timeout: timeout)
        let summaries = agents["agents"]?.array?.compactMap(AgentSummary.init) ?? []
        let approvalItems = approvals.map { $0["approvals"]?.array ?? $0["items"]?.array ?? $0.array ?? [] } ?? []
        let questionItems = questions.map { $0["questions"]?.array ?? $0.array ?? [] } ?? []
        return BackgroundRefreshSnapshot(
            agents: summaries,
            defaultAgentId: agents["defaultId"]?.text ?? summaries.first?.id ?? "main",
            sessions: (sessions["sessions"]?.array?.compactMap(SessionRow.init) ?? []).filter { !$0.isArchived },
            approvals: approvalItems.compactMap(ExecApproval.init),
            questions: questionItems.compactMap(QuestionPrompt.init).filter { $0.isAnswerable() })
    }

    private static func fetch(_ profile: GatewayProfile, connector: any IntentConnector, timeout: TimeInterval) async -> Outcome {
        guard let connection = try? await connector.connect(profile, timeout: timeout) else { return .failed }
        let snapshot = try? await Self.fetch(connection, timeout: timeout)
        await connection.close()
        return snapshot.map(Outcome.snapshot) ?? .failed
    }

    /// The body's result, or nil when `seconds` pass or the caller is cancelled first; the body is
    /// cancelled then and closes its connection as it unwinds.
    private static func bounded<T: Sendable>(seconds: TimeInterval, timer wait: @escaping @Sendable (TimeInterval) async -> Void, _ body: @escaping @MainActor () async -> T) async -> T? {
        let (results, continuation) = AsyncStream<T?>.makeStream()
        let work = Task { @MainActor in
            continuation.yield(await body())
            continuation.finish()
        }
        let timer = Task {
            await wait(seconds)
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return await withTaskCancellationHandler {
            for await result in results { return result }
            return nil
        } onCancel: {
            continuation.yield(nil)
            continuation.finish()
        }
    }
}
