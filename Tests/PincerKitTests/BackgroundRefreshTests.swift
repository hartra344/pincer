import Foundation
import Testing
import UserNotifications
@testable import PincerKit

@Suite("Background refresh")
struct BackgroundRefreshTests {
    static let nowMs = Date().timeIntervalSince1970 * 1000

    static func defaults() -> UserDefaults {
        let suite = "pincer.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func row(_ key: String, activity: Double, unread: Bool = true, extra: String = "") -> SessionRow {
        SessionRow(Fixtures.json(#"""
        {"key":"\#(key)","label":"Chat \#(key.suffix(4))","unread":\#(unread),"lastActivityAt":\#(activity),
         "lastMessagePreview":"Preview of \#(key.suffix(4))"\#(extra.isEmpty ? "" : ",\(extra)")}
        """#))!
    }

    static func approvalJSON(_ id: String, session: String? = nil, expiresAtMs: Double? = nil, allowed: String? = nil) -> JSONValue {
        let sessionField = session.map { #","sessionKey":"\#($0)""# } ?? ""
        let expiry = expiresAtMs ?? (nowMs + 600_000)
        let allowedField = allowed.map { #","allowedDecisions":\#($0)"# } ?? ""
        return Fixtures.json(#"{"id":"\#(id)","request":{"command":"ls -la"\#(sessionField)\#(allowedField)},"expiresAtMs":\#(expiry)}"#)
    }

    static func approval(_ id: String, session: String? = nil, expiresAtMs: Double? = nil, allowed: String? = nil) -> ExecApproval {
        ExecApproval(approvalJSON(id, session: session, expiresAtMs: expiresAtMs, allowed: allowed))!
    }

    static func question(_ id: String, session: String? = nil, status: String = "pending") -> QuestionPrompt {
        let sessionField = session.map { #","sessionKey":"\#($0)""# } ?? ""
        return QuestionPrompt(Fixtures.json(#"""
        {"id":"\#(id)","status":"\#(status)"\#(sessionField),"agentId":"main","expiresAtMs":\#(nowMs + 600_000),
         "questions":[{"questionId":"q","header":"H","question":"Which one?","options":[]}]}
        """#))!
    }

    static let agents = [AgentSummary(id: "main", name: "Claw", emoji: "🦞")]

    static func snapshot(_ sessions: [SessionRow] = [], approvals: [ExecApproval] = [], questions: [QuestionPrompt] = []) -> BackgroundRefreshSnapshot {
        BackgroundRefreshSnapshot(agents: agents, defaultAgentId: "main", sessions: sessions, approvals: approvals, questions: questions)
    }

    static func plan(_ snapshot: BackgroundRefreshSnapshot, cursor: BackgroundRefreshCursor?, filter: BackgroundRefreshFilter = .init(),
                     gatewayId: UUID = UUID()) -> (requests: [UNNotificationRequest], cursor: BackgroundRefreshCursor)
    {
        BackgroundRefreshPlanner.plan(snapshot: snapshot, cursor: cursor, filter: filter, gatewayId: gatewayId, gatewayName: "Home")
    }

    static let base = BackgroundRefreshCursor(activityMs: 1000, approvalIds: [], questionIds: [])
    static func key(_ n: Int) -> String { "agent:main:dashboard:c\(n)" }

    // MARK: Planner

    @Test func baselineHasCursorAndNoNotifications() {
        let snapshot = Self.snapshot([Self.row(Self.key(1), activity: 5000), Self.row(Self.key(2), activity: 7000)],
                                     approvals: [Self.approval("a1")], questions: [Self.question("q1")])
        let result = Self.plan(snapshot, cursor: nil)
        #expect(result.requests.isEmpty)
        #expect(result.cursor.activityMs == 7000)
        #expect(result.cursor.approvalIds == ["a1"])
        #expect(result.cursor.questionIds == ["q1"])
        #expect(BackgroundRefreshPlanner.cursor(for: snapshot) == result.cursor)
    }

    @Test func onlyNewerUnreadRowsNotify() {
        let snapshot = Self.snapshot([
            Self.row(Self.key(1), activity: 900),
            Self.row(Self.key(2), activity: 1000),
            Self.row(Self.key(3), activity: 2000),
            Self.row(Self.key(4), activity: 3000, unread: false),
            Self.row(Self.key(5), activity: 4000, extra: #""hasActiveRun":true"#),
        ])
        let result = Self.plan(snapshot, cursor: Self.base)
        #expect(result.requests.map(\.identifier) == ["reply:\(Self.key(3)):2000"])
        #expect(result.cursor.activityMs == 4000)
    }

    @Test func replyContentMatchesTheLivePath() throws {
        let gatewayId = UUID()
        let target = Self.row(Self.key(1), activity: 2000)
        let result = Self.plan(Self.snapshot([target]), cursor: Self.base, gatewayId: gatewayId)
        let request = try #require(result.requests.first)
        #expect(request.identifier == "reply:\(target.key):2000")
        #expect(request.content.title == "🦞 \(target.title) · Claw")
        #expect(request.content.body == "Preview of \(Self.key(1).suffix(4))")
        #expect(request.content.categoryIdentifier == "reply")
        #expect(request.content.threadIdentifier == "\(gatewayId.uuidString)|\(target.key)")
        #expect(request.content.userInfo["gateway"] as? String == gatewayId.uuidString)
        #expect(request.content.userInfo["session"] as? String == target.key)
        #expect(request.trigger == nil)
    }

    @Test func replyWithoutPreviewSaysNewActivity() throws {
        let bare = SessionRow(Fixtures.json(#"{"key":"\#(Self.key(1))","unread":true,"lastActivityAt":2000}"#))!
        let request = try #require(Self.plan(Self.snapshot([bare]), cursor: Self.base).requests.first)
        #expect(request.content.body == "New activity")
    }

    @Test func approvalsNotifyOnceAndMatchTheLivePath() throws {
        let gatewayId = UUID()
        let pending = Self.approval("a1", session: Self.key(1))
        let snapshot = Self.snapshot(approvals: [pending])
        let first = Self.plan(snapshot, cursor: Self.base, gatewayId: gatewayId)
        let request = try #require(first.requests.first)
        #expect(request.identifier == "approval:a1")
        #expect(request.content.title == "Approval needed · Home")
        #expect(request.content.body == "ls -la")
        #expect(request.content.categoryIdentifier == Notifier.category(for: pending))
        #expect(request.content.interruptionLevel == .timeSensitive)
        #expect(request.content.userInfo["gateway"] as? String == gatewayId.uuidString)
        #expect(request.content.userInfo["session"] as? String == Self.key(1))
        #expect(request.content.userInfo["approval"] as? String == "a1")
        #expect(first.cursor.approvalIds == ["a1"])

        let second = Self.plan(snapshot, cursor: first.cursor, gatewayId: gatewayId)
        #expect(second.requests.isEmpty)
    }

    @Test func expiredApprovalsAreIgnored() {
        let snapshot = Self.snapshot(approvals: [Self.approval("old", expiresAtMs: 1_000)])
        let result = Self.plan(snapshot, cursor: Self.base)
        #expect(result.requests.isEmpty)
        #expect(!result.cursor.approvalIds.contains("old"))
    }

    @Test func approvalsNotifyEvenForHiddenChats() {
        let hidden = "agent:main:cron:job1"
        let result = Self.plan(Self.snapshot(approvals: [Self.approval("a1", session: hidden)]), cursor: Self.base)
        #expect(result.requests.map(\.identifier) == ["approval:a1"])
    }

    @Test func questionsNotifyOnceAndSkipTerminalOnes() throws {
        let gatewayId = UUID()
        let snapshot = Self.snapshot(questions: [Self.question("q1", session: Self.key(1)), Self.question("q2", status: "answered")])
        let first = Self.plan(snapshot, cursor: Self.base, gatewayId: gatewayId)
        let request = try #require(first.requests.first)
        #expect(first.requests.count == 1)
        #expect(request.content.title.contains("Claw has a question"))
        #expect(request.content.userInfo["gateway"] as? String == gatewayId.uuidString)
        #expect(first.cursor.questionIds == ["q1"])
        #expect(Self.plan(snapshot, cursor: first.cursor, gatewayId: gatewayId).requests.isEmpty)
    }

    @Test func cursorKeepsOnlyPendingIds() {
        let cursor = BackgroundRefreshCursor(activityMs: 1000, approvalIds: ["gone", "a1"], questionIds: ["qgone", "q1"])
        let snapshot = Self.snapshot(approvals: [Self.approval("a1")], questions: [Self.question("q1")])
        let result = Self.plan(snapshot, cursor: cursor)
        #expect(result.requests.isEmpty)
        #expect(result.cursor.approvalIds == ["a1"])
        #expect(result.cursor.questionIds == ["q1"])
    }

    @Test func cursorIdListsAreBounded() {
        let approvals = (0..<250).map { Self.approval("a\($0)") }
        let result = Self.plan(Self.snapshot(approvals: approvals), cursor: nil)
        #expect(result.cursor.approvalIds.count <= 200)
    }

    @Test func cursorNeverMovesBackwards() {
        let result = Self.plan(Self.snapshot([Self.row(Self.key(1), activity: 10)]), cursor: Self.base)
        #expect(result.cursor.activityMs >= 1000)
    }

    @Test func maxPerGatewayKeepsNewestAndAdvancesPastTheRest() {
        let rows = (1...15).map { Self.row(Self.key($0), activity: Double(1000 + $0 * 10)) }
        let result = Self.plan(Self.snapshot(rows), cursor: Self.base)
        #expect(BackgroundRefreshPlanner.maxPerGateway == 10)
        #expect(result.requests.count == 10)
        let newestFirst = Set(result.requests.map(\.identifier))
        for n in 6...15 { #expect(newestFirst.contains("reply:\(Self.key(n)):\(1000 + n * 10)")) }
        #expect(result.cursor.activityMs == 1150)
        #expect(Self.plan(Self.snapshot(rows), cursor: result.cursor).requests.isEmpty)
    }

    @Test func capAppliesToRepliesOnly() {
        let rows = (1...12).map { Self.row(Self.key($0), activity: Double(1000 + $0 * 10)) }
        let approvals = (1...12).map { Self.approval("a\($0)") }
        let questions = (1...3).map { Self.question("q\($0)") }
        let result = Self.plan(Self.snapshot(rows, approvals: approvals, questions: questions), cursor: Self.base)
        let ids = result.requests.map(\.identifier)
        #expect(ids.filter { $0.hasPrefix("reply:") }.count == 10)
        #expect(ids.filter { $0.hasPrefix("approval:") }.count == 12)
        #expect(result.requests.count == 25)
        #expect(result.cursor.questionIds.count == 3)
    }

    @Test func advanceMovesAnExistingCursorForward() {
        let store = BackgroundRefreshCursorStore(defaults: Self.defaults())
        let id = UUID()
        store.advance(gatewayId: id, activityMs: 5, approvalId: "a", questionId: "q")
        #expect(store.cursor(for: id) == nil)

        store.save(Self.base, for: id)
        store.advance(gatewayId: id, activityMs: 500)
        #expect(store.cursor(for: id)?.activityMs == 1000)
        store.advance(gatewayId: id, activityMs: 2500, approvalId: "a1", questionId: "q1")
        store.advance(gatewayId: id, approvalId: "a1")
        store.advance(gatewayId: id, approvalId: "a2")
        #expect(store.cursor(for: id) == BackgroundRefreshCursor(activityMs: 2500, approvalIds: ["a1", "a2"], questionIds: ["q1"]))
    }

    @Test func advanceKeepsIdListsBounded() {
        let store = BackgroundRefreshCursorStore(defaults: Self.defaults())
        let id = UUID()
        store.save(Self.base, for: id)
        for n in 0..<250 { store.advance(gatewayId: id, approvalId: "a\(n)") }
        let ids = store.cursor(for: id)?.approvalIds ?? []
        #expect(ids.count == 200 && ids.last == "a249")
    }

    // MARK: Filters

    @Test func subagentsAndArchivedNeverNotify() {
        let rows = [
            Self.row("agent:main:subagent:x", activity: 2000, extra: #""parentSessionKey":"agent:main:main""#),
            Self.row(Self.key(1), activity: 2100, extra: #""archived":true"#),
            Self.row(Self.key(2), activity: 2200),
        ]
        let result = Self.plan(Self.snapshot(rows), cursor: Self.base)
        #expect(result.requests.map(\.identifier) == ["reply:\(Self.key(2)):2200"])
    }

    @Test func hiddenKindsAreMutedUnlessShown() {
        let automation = Self.row("agent:main:cron:job1", activity: 2000)
        let slash = Self.row("agent:main:slash:s1", activity: 2100)
        let snapshot = Self.snapshot([automation, slash])
        #expect(Self.plan(snapshot, cursor: Self.base).requests.isEmpty)
        #expect(Self.plan(snapshot, cursor: Self.base).cursor.activityMs == 2100)
        #expect(Self.plan(snapshot, cursor: Self.base, filter: .init(showAutomations: true)).requests.map(\.identifier)
            == ["reply:agent:main:cron:job1:2000"])
        #expect(Self.plan(snapshot, cursor: Self.base, filter: .init(showSlashCommands: true)).requests.map(\.identifier)
            == ["reply:agent:main:slash:s1:2100"])
        #expect(Self.plan(snapshot, cursor: Self.base, filter: .init(showAutomations: true, showSlashCommands: true)).requests.count == 2)
    }

    @Test func filterLoadsPerGatewayToggles() {
        let defaults = Self.defaults()
        let shown = UUID(), other = UUID()
        defaults.set(true, forKey: "pincer.showAutomations.\(shown.uuidString)")
        defaults.set(true, forKey: "pincer.showSlashCommands.\(shown.uuidString)")
        #expect(BackgroundRefreshFilter.load(gatewayId: shown, defaults: defaults) == .init(showAutomations: true, showSlashCommands: true))
        #expect(BackgroundRefreshFilter.load(gatewayId: other, defaults: defaults) == .init())
    }

    @Test func filterNotifiesDecision() {
        let filter = BackgroundRefreshFilter()
        #expect(filter.notifies(Self.row(Self.key(1), activity: 1)))
        #expect(!filter.notifies(Self.row("agent:main:cron:j", activity: 1)))
        #expect(!filter.notifies(Self.row(Self.key(1), activity: 1, extra: #""archived":true"#)))
    }

    // MARK: Cursor store & mode

    @Test func cursorStoreRoundTrips() {
        let defaults = Self.defaults()
        let store = BackgroundRefreshCursorStore(defaults: defaults)
        let id = UUID()
        #expect(store.cursor(for: id) == nil)
        let cursor = BackgroundRefreshCursor(activityMs: 5, approvalIds: ["a"], questionIds: ["q"])
        store.save(cursor, for: id)
        #expect(store.cursor(for: id) == cursor)
        #expect(defaults.data(forKey: "pincer.refresh.cursor.\(id.uuidString)") != nil)
        #expect(store.cursor(for: UUID()) == nil)
        store.remove(for: id)
        #expect(store.cursor(for: id) == nil)
    }

    @Test func modeDefaultsToRefreshWithoutARelay() {
        let defaults = Self.defaults()
        #expect(ClosedAppDelivery.current(defaults) == .backgroundRefresh)
        defaults.set("", forKey: "pincer.pushRelay")
        #expect(ClosedAppDelivery.current(defaults) == .backgroundRefresh)
    }

    @Test func modeDefaultsToPushWithARelay() {
        let defaults = Self.defaults()
        defaults.set("https://relay.example", forKey: "pincer.pushRelay")
        #expect(ClosedAppDelivery.current(defaults) == .pushRelay)
    }

    @Test func explicitModeWinsAndRoundTrips() {
        let defaults = Self.defaults()
        defaults.set("https://relay.example", forKey: "pincer.pushRelay")
        for mode in ClosedAppDelivery.allCases {
            ClosedAppDelivery.set(mode, defaults)
            #expect(ClosedAppDelivery.current(defaults) == mode)
        }
        #expect(defaults.string(forKey: "pincer.closedAppDelivery") == "off")
        #expect(ClosedAppDelivery.pushRelay.rawValue == "push" && ClosedAppDelivery.backgroundRefresh.rawValue == "refresh")
        defaults.set("bogus", forKey: ClosedAppDelivery.key)
        #expect(ClosedAppDelivery.current(defaults) == .pushRelay)
        #expect(Set(ClosedAppDelivery.allCases.map(\.label)) == ["Push relay", "Background refresh", "Off"])
    }

    // MARK: Run

    /// Ends a run's budget on cue; waiters arriving after `expire()` return at once.
    final class BudgetGate: @unchecked Sendable {
        private let lock = NSLock()
        private var expired: Bool
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        init(expired: Bool = false) { self.expired = expired }

        var timer: @Sendable (TimeInterval) async -> Void { { [self] _ in await wait() } }

        func wait() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { register(id, $0) }
            } onCancel: {
                resume(id)
            }
        }

        func expire() {
            lock.lock()
            expired = true
            let all = waiters.values
            waiters = [:]
            lock.unlock()
            for waiter in all { waiter.resume() }
        }

        private func register(_ id: UUID, _ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            let now = expired || Task.isCancelled
            if !now { waiters[id] = continuation }
            lock.unlock()
            if now { continuation.resume() }
        }

        private func resume(_ id: UUID) {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume()
        }
    }

    @MainActor
    final class Posts {
        var batches: [[UNNotificationRequest]] = []
        var identifiers: [String] { batches.flatMap { $0.map(\.identifier) } }
    }

    @MainActor
    final class FakeConnection: IntentConnection {
        var delay: Duration = .zero
        var failing: Set<String> = []
        var sessions: [SessionRow] = []
        var approvals: [JSONValue] = []
        private(set) var methods: [String] = []
        private(set) var closed = false
        private(set) var closeCount = 0
        private(set) var observerCalls = 0

        func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            methods.append(method)
            if delay > .zero { try await Task.sleep(for: delay) }
            if failing.contains(method) { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method \(method)", details: nil) }
            switch method {
            case "agents.list": return Fixtures.json(#"{"defaultId":"main","agents":[{"id":"main","identity":{"name":"Claw","emoji":"🦞"}}]}"#)
            case "sessions.list": return .object(["sessions": .array(sessions.map(\.raw))])
            case "exec.approval.list": return .object(["approvals": .array(approvals)])
            case "question.list": return Fixtures.json(#"{"questions":[]}"#)
            default: return Fixtures.json("{}")
            }
        }

        func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int { observerCalls += 1; return 0 }
        func stopObserving(_ token: Int) {}
        func close() async { closed = true; closeCount += 1 }
    }

    @MainActor
    struct FakeConnector: IntentConnector {
        var connections: [UUID: FakeConnection] = [:]
        var unreachable: Set<UUID> = []

        func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
            if unreachable.contains(profile.id) { throw IntentError.unreachable(gateway: profile.name) }
            return connections[profile.id]!
        }

        func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
        func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
    }

    @MainActor
    struct Rig {
        let defaults = BackgroundRefreshTests.defaults()
        let profile = GatewayProfile(name: "Home", url: "wss://home.example", authMode: .token)
        let connection = FakeConnection()
        let posts = Posts()
        var cursors: BackgroundRefreshCursorStore { BackgroundRefreshCursorStore(defaults: defaults) }

        init(mode: ClosedAppDelivery? = .backgroundRefresh, notifications: Bool = true) {
            if let mode { ClosedAppDelivery.set(mode, defaults) }
            defaults.set(notifications, forKey: "pincer.notifications")
        }

        func refresher(unreachable: Bool = false, timer: (@Sendable (TimeInterval) async -> Void)? = nil) -> BackgroundRefresh {
            var connector = FakeConnector(connections: [profile.id: connection])
            if unreachable { connector.unreachable = [profile.id] }
            let posts = self.posts
            return BackgroundRefresh(profiles: { [profile] in [profile] }, connector: connector, cursors: cursors, defaults: defaults,
                                     post: { posts.batches.append($0) },
                                     timer: timer ?? { try? await Task.sleep(for: .seconds($0)) })
        }
    }

    @Test @MainActor func runSkipsUnlessRefreshModeAndNotificationsOn() async {
        for (mode, notifications) in [(ClosedAppDelivery.pushRelay, true), (.off, true), (.backgroundRefresh, false)] {
            let rig = Rig(mode: mode, notifications: notifications)
            let report = await rig.refresher().run()
            #expect(report.skipped)
            #expect(report.posted == 0 && rig.posts.batches.isEmpty)
            #expect(rig.connection.methods.isEmpty)
            #expect(rig.cursors.cursor(for: rig.profile.id) == nil)
        }
    }

    @Test @MainActor func firstRunBaselinesThenNotifiesOnceThenDedupes() async {
        let rig = Rig()
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        let refresher = rig.refresher()

        let baseline = await refresher.run()
        #expect(!baseline.skipped && baseline.posted == 0 && baseline.aborted.isEmpty && baseline.failed.isEmpty)
        #expect(rig.posts.identifiers.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id)?.activityMs == 5000)
        #expect(rig.connection.closed)
        for method in ["agents.list", "sessions.list", "exec.approval.list", "question.list"] {
            #expect(rig.connection.methods.contains(method))
        }

        rig.connection.sessions = [Self.row(Self.key(1), activity: 9000)]
        rig.connection.approvals = [Self.approvalJSON("a1")]
        let second = await refresher.run()
        #expect(second.posted == 2)
        #expect(Set(rig.posts.identifiers) == ["reply:\(Self.key(1)):9000", "approval:a1"])
        #expect(rig.cursors.cursor(for: rig.profile.id)?.activityMs == 9000)

        let third = await refresher.run()
        #expect(third.posted == 0)
        #expect(rig.posts.identifiers.count == 2)
    }

    @Test @MainActor func missingQuestionAndApprovalMethodsCountAsEmpty() async {
        let rig = Rig()
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        rig.connection.failing = ["question.list", "exec.approval.list"]
        let refresher = rig.refresher()
        _ = await refresher.run()
        rig.connection.sessions = [Self.row(Self.key(1), activity: 6000)]
        let report = await refresher.run()
        #expect(report.posted == 1 && report.failed.isEmpty)
    }

    @Test @MainActor func unreachableGatewayFailsWithoutTouchingTheCursor() async {
        let rig = Rig()
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        rig.cursors.save(saved, for: rig.profile.id)
        let report = await rig.refresher(unreachable: true).run()
        #expect(report.failed == [rig.profile.id] && report.posted == 0)
        #expect(rig.posts.batches.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id) == saved)
    }

    @Test @MainActor func failedSessionsListLeavesCursorUnchanged() async {
        let rig = Rig()
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        rig.cursors.save(saved, for: rig.profile.id)
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        rig.connection.failing = ["sessions.list"]
        let report = await rig.refresher().run()
        #expect(report.failed == [rig.profile.id])
        #expect(rig.posts.identifiers.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id) == saved)
    }

    @Test @MainActor func timeBudgetAbortPostsNothingAndKeepsTheCursor() async {
        let rig = Rig()
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        rig.cursors.save(saved, for: rig.profile.id)
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        rig.connection.approvals = [Self.approvalJSON("a1")]
        rig.connection.delay = .seconds(3600)
        let gate = BudgetGate()
        let refresher = rig.refresher(timer: gate.timer)
        let task = Task { @MainActor in await refresher.run(budget: 25) }
        #expect(await Self.eventually(timeout: .seconds(30)) { !rig.connection.methods.isEmpty })
        gate.expire()
        let report = await task.value
        #expect(report.aborted.contains(rig.profile.id))
        #expect(report.posted == 0 && rig.posts.batches.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id) == saved)
        // The abandoned fetch unwinds and releases its connection.
        let closed = await Self.eventually(timeout: .seconds(30)) { rig.connection.closed }
        #expect(closed)
    }

    @Test @MainActor func tinyBudgetAborts() async {
        let rig = Rig()
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        rig.cursors.save(saved, for: rig.profile.id)
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        rig.connection.delay = .seconds(3600)
        let report = await rig.refresher(timer: BudgetGate(expired: true).timer).run(budget: 25)
        #expect(report.aborted == [rig.profile.id] && report.posted == 0 && rig.posts.batches.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id) == saved)
    }

    @MainActor
    static func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test @MainActor func cancellationPostsNothingAndKeepsTheCursor() async {
        let rig = Rig()
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        rig.cursors.save(saved, for: rig.profile.id)
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        rig.connection.delay = .seconds(3600)
        let refresher = rig.refresher()
        let task = Task { @MainActor in await refresher.run() }
        #expect(await Self.eventually(timeout: .seconds(30)) { !rig.connection.methods.isEmpty })
        task.cancel()
        let report = await task.value
        #expect(report.aborted.contains(rig.profile.id))
        #expect(report.posted == 0 && rig.posts.batches.isEmpty)
        #expect(rig.cursors.cursor(for: rig.profile.id) == saved)
    }

    @Test @MainActor func runRecordsStatus() async {
        let rig = Rig()
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        let refresher = rig.refresher()
        _ = await refresher.run()
        #expect(rig.defaults.object(forKey: "pincer.refresh.lastRun") as? Date != nil)
        #expect(rig.defaults.string(forKey: "pincer.refresh.lastResult") == "Up to date")
        rig.connection.sessions = [Self.row(Self.key(1), activity: 6000)]
        _ = await refresher.run()
        #expect(rig.defaults.string(forKey: "pincer.refresh.lastResult") == "1 new")
    }

    @Test @MainActor func slowGatewayAbortsWhileFastOneCommits() async {
        let defaults = Self.defaults()
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        let slow = GatewayProfile(name: "Slow", url: "wss://slow.example", authMode: .token)
        let fast = GatewayProfile(name: "Fast", url: "wss://fast.example", authMode: .token)
        let slowConnection = FakeConnection(), fastConnection = FakeConnection()
        slowConnection.delay = .seconds(3600)
        slowConnection.sessions = [Self.row(Self.key(1), activity: 5000)]
        fastConnection.sessions = [Self.row(Self.key(2), activity: 5000)]
        let cursors = BackgroundRefreshCursorStore(defaults: defaults)
        let saved = BackgroundRefreshCursor(activityMs: 100, approvalIds: [], questionIds: [])
        cursors.save(saved, for: slow.id)
        cursors.save(saved, for: fast.id)
        let posts = Posts()
        let gate = BudgetGate()
        let refresher = BackgroundRefresh(
            profiles: { [slow, fast] },
            connector: FakeConnector(connections: [slow.id: slowConnection, fast.id: fastConnection]),
            cursors: cursors, defaults: defaults, post: { posts.batches.append($0) }, timer: gate.timer)

        let task = Task { @MainActor in await refresher.run(budget: 25) }
        #expect(await Self.eventually(timeout: .seconds(30)) { fastConnection.closed && !slowConnection.methods.isEmpty })
        gate.expire()
        let report = await task.value
        #expect(report.aborted == [slow.id] && report.failed.isEmpty && report.posted == 1)
        #expect(posts.identifiers == ["reply:\(Self.key(2)):5000"])
        #expect(cursors.cursor(for: slow.id) == saved)
        #expect(cursors.cursor(for: fast.id)?.activityMs == 5000)
        #expect(defaults.string(forKey: "pincer.refresh.lastResult") == "1 new · Couldn't reach Slow")
    }

    @Test @MainActor func resultStrings() async {
        let a = GatewayProfile(name: "Alpha", url: "wss://a.example", authMode: .token)
        let b = GatewayProfile(name: "Beta", url: "wss://b.example", authMode: .token)
        let defaults = Self.defaults()
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        let cursors = BackgroundRefreshCursorStore(defaults: defaults)
        let connections = [a.id: FakeConnection(), b.id: FakeConnection()]
        func run(unreachable: Set<UUID> = []) async -> String? {
            var connector = FakeConnector(connections: connections)
            connector.unreachable = unreachable
            let refresher = BackgroundRefresh(profiles: { [a, b] }, connector: connector, cursors: cursors, defaults: defaults, post: { _ in })
            _ = await refresher.run()
            return defaults.string(forKey: "pincer.refresh.lastResult")
        }
        connections[a.id]!.sessions = [Self.row(Self.key(1), activity: 1000)]
        connections[b.id]!.sessions = [Self.row(Self.key(2), activity: 1000)]
        _ = await run()
        #expect(await run() == "Up to date")
        #expect(await run(unreachable: [b.id]) == "Couldn't reach Beta")
        #expect(await run(unreachable: [a.id, b.id]) == "Couldn't reach Alpha, Beta")
        connections[a.id]!.sessions = [Self.row(Self.key(1), activity: 2000), Self.row(Self.key(3), activity: 2100)]
        #expect(await run(unreachable: [b.id]) == "2 new · Couldn't reach Beta")
        connections[a.id]!.sessions = [Self.row(Self.key(1), activity: 3000)]
        #expect(await run() == "1 new")
    }

    @Test @MainActor func skippedRunKeepsTheLastStatus() async {
        let rig = Rig()
        rig.connection.sessions = [Self.row(Self.key(1), activity: 5000)]
        _ = await rig.refresher().run()
        let ran = rig.defaults.object(forKey: "pincer.refresh.lastRun") as? Date
        #expect(ran != nil)
        ClosedAppDelivery.set(.off, rig.defaults)
        let report = await rig.refresher().run()
        #expect(report.skipped)
        #expect(rig.defaults.object(forKey: "pincer.refresh.lastRun") as? Date == ran)
        #expect(rig.defaults.string(forKey: "pincer.refresh.lastResult") == "Up to date")
    }

    @Test @MainActor func runOnlyIssuesTheFourReadOnlyRequestsAndClosesEverything() async {
        let defaults = Self.defaults()
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        let profiles = [GatewayProfile(name: "A", url: "wss://a.example", authMode: .token),
                        GatewayProfile(name: "B", url: "wss://b.example", authMode: .token)]
        let connections = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, FakeConnection()) })
        for connection in connections.values { connection.sessions = [Self.row(Self.key(1), activity: 5000)] }
        let refresher = BackgroundRefresh(
            profiles: { profiles }, connector: FakeConnector(connections: connections),
            cursors: BackgroundRefreshCursorStore(defaults: defaults), defaults: defaults, post: { _ in })
        _ = await refresher.run()
        connections.values.forEach { $0.sessions = [Self.row(Self.key(1), activity: 6000)] }
        _ = await refresher.run()

        let allowed: Set<String> = ["agents.list", "sessions.list", "exec.approval.list", "question.list"]
        for connection in connections.values {
            #expect(!connection.methods.isEmpty && Set(connection.methods) == allowed)
            #expect(connection.observerCalls == 0)
            #expect(connection.closed && connection.closeCount == 2)
        }
    }

    @Test @MainActor func constants() {
        #expect(BackgroundRefresh.taskIdentifier == "chat.pincer.refresh")
        #expect(BackgroundRefresh.defaultBudget == 25)
        #expect(BackgroundRefresh.interval == 15 * 60)
    }
}
