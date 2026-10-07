import Foundation
import PincerPush
import Testing
import UserNotifications
@testable import PincerKit

/// #294: a content-available push wakes Pincer to catch up on what the gateway didn't push.
@Suite("Silent push refresh")
struct SilentPushRefreshTests {
    typealias Base = BackgroundRefreshTests

    static let gateway = UUID()
    static let chatKey = "agent:main:main"

    static func request(_ id: String, info: [String: String]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "t"
        content.userInfo = info
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    static func message(_ json: String, gatewayId: UUID = gateway) -> PushMessage {
        PushMessage(json: Data(json.utf8), gatewayId: gatewayId)!
    }

    // MARK: PushedTargets

    @Test func userInfosCollectSessionsAndApprovalsAndIgnoreEmptyValues() {
        let gid = Self.gateway.uuidString
        let targets = PushedTargets(userInfos: [
            ["gateway": gid, "session": "s1"],
            ["gateway": gid, "approval": "a1", "session": "s2"],
            ["gateway": gid, "session": ""],
            ["gateway": gid, "approval": ""],
            ["gateway": "", "session": "s3"],
            ["session": "s4"],
            ["other": "x"],
        ])
        #expect(targets.sessions.contains("\(gid)|s1") && targets.sessions.contains("\(gid)|s2"))
        #expect(!targets.sessions.contains { $0.hasSuffix("|") || $0.hasSuffix("s3") || $0.hasSuffix("s4") })
        #expect(targets.approvals == ["\(gid)|a1"])
        let asked = PushedTargets(userInfos: [["gateway": gid, "question": "q1"], ["gateway": gid, "question": ""]])
        #expect(asked.questions == ["\(gid)|q1"])
        #expect(PushedTargets(userInfos: []) == PushedTargets())
    }

    @Test func gatewayIdsAreCompareUppercased() {
        let gid = Self.gateway.uuidString
        let targets = PushedTargets(userInfos: [["gateway": gid.lowercased(), "session": "s1"]])
        #expect(targets.covers(Self.request("reply:s1:1", info: ["gateway": gid, "session": "s1"])))
        #expect(PushedTargets(sessions: ["\(gid)|s1"]).covers(
            Self.request("reply:s1:1", info: ["gateway": gid.lowercased(), "session": "s1"])))
    }

    @Test func messageMapsChatToSessionAndApprovalToApprovalId() {
        let gid = Self.gateway.uuidString
        let chat = PushedTargets(message: Self.message(#"{"title":"Claw","body":"Done","url":"chat/main"}"#))
        #expect(chat == PushedTargets(sessions: ["\(gid)|\(Self.chatKey)"]))
        let approval = PushedTargets(message: Self.message(
            #"{"title":"OpenClaw approval requested","body":"exec","url":"approve/a1"}"#))
        #expect(approval.approvals == ["\(gid)|a1"])
        let question = PushedTargets(message: Self.message(#"{"title":"Claw asks","body":"Which?","url":"ask/q1"}"#))
        #expect(question == PushedTargets(questions: ["\(gid)|q1"]))
        let other = PushedTargets(message: Self.message(#"{"title":"Hello","body":"x","url":"sessions"}"#))
        #expect(other.sessions.isEmpty && other.approvals.isEmpty)
    }

    @Test func unionCombines() {
        let merged = PushedTargets(sessions: ["a|1"], approvals: ["a|x"], questions: ["a|q"])
            .union(PushedTargets(sessions: ["b|2"], approvals: ["b|y"], questions: ["b|r"]))
        #expect(merged == PushedTargets(sessions: ["a|1", "b|2"], approvals: ["a|x", "b|y"], questions: ["a|q", "b|r"]))
    }

    @Test func coversRules() {
        let gid = Self.gateway.uuidString
        let other = UUID().uuidString
        let targets = PushedTargets(sessions: ["\(gid)|s1"], approvals: ["\(gid)|a1"])

        // Replies match by gateway and session.
        #expect(targets.covers(Self.request("reply:s1:5", info: ["gateway": gid, "session": "s1"])))
        #expect(!targets.covers(Self.request("reply:s2:5", info: ["gateway": gid, "session": "s2"])))
        #expect(!targets.covers(Self.request("reply:s1:5", info: ["gateway": other, "session": "s1"])))

        // Approvals match by id only, even when the approval's chat wasn't pushed or differs.
        #expect(targets.covers(Self.request("approval:a1", info: ["gateway": gid, "approval": "a1", "session": "elsewhere"])))
        #expect(targets.covers(Self.request("approval:a1", info: ["gateway": gid, "approval": "a1"])))
        #expect(!targets.covers(Self.request("approval:a2", info: ["gateway": gid, "approval": "a2", "session": "s1"])),
                "a pushed chat doesn't cover a different approval")
        #expect(!targets.covers(Self.request("approval:a1", info: ["gateway": other, "approval": "a1"])))

        // Questions match by id only: a pushed chat never covers one.
        #expect(!targets.covers(Self.request("question:q1", info: ["gateway": gid, "session": "s1"])))
        let asked = PushedTargets(questions: ["\(gid)|q1"])
        #expect(asked.covers(Self.request("question:q1", info: ["gateway": gid, "session": "other"])))
        #expect(asked.covers(Self.request("question:q1", info: ["gateway": gid])))
        #expect(!asked.covers(Self.request("question:q2", info: ["gateway": gid, "session": "s1"])))
        #expect(!asked.covers(Self.request("question:q1", info: ["gateway": other])))
        #expect(!asked.covers(Self.request("reply:s1:5", info: ["gateway": gid, "session": "s1"])))
        // No session, never covered (overflow summary).
        #expect(!targets.covers(Self.request("refresh-summary:1:2", info: ["gateway": gid])))
        #expect(!targets.covers(Self.request("x", info: [:])))
        #expect(!PushedTargets().covers(Self.request("reply:s1:5", info: ["gateway": gid, "session": "s1"])))
    }

    // MARK: run(trigger:)

    @MainActor
    final class Delivered {
        var infos: [[AnyHashable: Any]] = []
        var calls = 0
    }

    @MainActor
    static func refresher(_ rig: Base.Rig, delivered: Delivered = Delivered(), unreachable: Bool = false,
                          timer: (@Sendable (TimeInterval) async -> Void)? = nil) -> BackgroundRefresh {
        var connector = Base.FakeConnector(connections: [rig.profile.id: rig.connection])
        if unreachable { connector.unreachable = [rig.profile.id] }
        let posts = rig.posts, badges = rig.badges
        return BackgroundRefresh(
            profiles: { [profile = rig.profile] in [profile] }, connector: connector, cursors: rig.cursors, defaults: rig.defaults,
            post: { posts.batches.append($0) }, setBadge: { badges.values.append($0) },
            delivered: { delivered.calls += 1; return delivered.infos },
            timer: timer ?? { try? await Task.sleep(for: .seconds($0)) })
    }

    static func questionJSON(_ id: String, _ session: String) -> JSONValue {
        Fixtures.json(#"""
        {"id":"\#(id)","status":"pending","sessionKey":"\#(session)","agentId":"main","expiresAtMs":\#(Base.nowMs + 600_000),
         "questions":[{"questionId":"q","header":"H","question":"Which one?","options":[]}]}
        """#)
    }

    @MainActor
    final class QuestionConnection: IntentConnection {
        let base: Base.FakeConnection
        let questions: [JSONValue]
        init(base: Base.FakeConnection, questions: [JSONValue]) { self.base = base; self.questions = questions }

        func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            if method == "question.list" { return .object(["questions": .array(questions)]) }
            return try await base.request(method, params, timeout: timeout)
        }

        func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int { 0 }
        func stopObserving(_ token: Int) {}
        func close() async { await base.close() }
    }

    @MainActor
    struct QuestionConnector: IntentConnector {
        let connection: QuestionConnection
        func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection { connection }
        func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
        func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
    }

    @Test @MainActor func triggersAreGatedByMode() async {
        let cases: [(ClosedAppDelivery, Bool, BackgroundRefresh.Trigger, Bool)] = [
            (.backgroundRefresh, true, .scheduled, true),
            (.pushRelay, true, .scheduled, false),
            (.off, true, .scheduled, false),
            (.pushRelay, true, .silentPush(PushedTargets()), true),
            (.backgroundRefresh, true, .silentPush(PushedTargets()), false),
            (.off, true, .silentPush(PushedTargets()), false),
            (.backgroundRefresh, false, .scheduled, false),
            (.pushRelay, false, .silentPush(PushedTargets()), false),
        ]
        for (mode, notifications, trigger, runs) in cases {
            let rig = Base.Rig(mode: mode, notifications: notifications)
            let report = await Self.refresher(rig).run(trigger: trigger)
            #expect(report.skipped == !runs, "\(mode) notifications=\(notifications) \(trigger)")
            #expect(rig.connection.methods.isEmpty == !runs)
        }
    }

    @Test @MainActor func scheduledRunsIgnoreDeliveredNotifications() async {
        let rig = Base.Rig(mode: .backgroundRefresh)
        rig.cursors.save(Base.base, for: rig.profile.id)
        rig.connection.sessions = [Base.row(Base.key(1), activity: 2000)]
        let delivered = Delivered()
        delivered.infos = [["gateway": rig.profile.id.uuidString, "session": Base.key(1)]]
        let report = await Self.refresher(rig, delivered: delivered).run()
        #expect(report.posted == 1 && delivered.calls == 0)
    }

    @Test @MainActor func silentPushSkipsWhatWasPushedOrDeliveredButStillAdvances() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        let gid = rig.profile.id.uuidString
        rig.connection.sessions = [
            Base.row(Base.key(1), activity: 2000),
            Base.row(Base.key(2), activity: 3000),
            Base.row(Base.key(3), activity: 4000),
        ]
        rig.connection.approvals = [Base.approvalJSON("a1"), Base.approvalJSON("a2")]
        let delivered = Delivered()
        delivered.infos = [["gateway": gid, "approval": "a1", "push": "1"]]
        let trigger = PushedTargets(sessions: ["\(gid)|\(Base.key(2))"])

        let report = await Self.refresher(rig, delivered: delivered).run(trigger: .silentPush(trigger))
        #expect(!report.skipped && delivered.calls == 1)
        #expect(!rig.posts.identifiers.contains("approval:a1"), "the delivered approval isn't posted twice")
        #expect(!rig.posts.identifiers.contains("reply:\(Base.key(2)):3000"), "the triggering push's chat isn't posted twice")
        #expect(rig.posts.identifiers.contains("reply:\(Base.key(3)):4000"), "an unpushed chat is still posted")
        #expect(rig.posts.identifiers.contains("approval:a2"), "an unpushed approval is still posted")
        #expect(rig.posts.identifiers.contains("reply:\(Base.key(1)):2000"))
        #expect(report.posted == 3 && rig.posts.identifiers.count == 3)
        let cursor = rig.cursors.cursor(for: rig.profile.id)
        #expect(cursor?.activityMs == 4000)
        #expect(cursor?.approvalIds.sorted() == ["a1", "a2"], "the cursor covers pushed items too")
        #expect(rig.badges.values == [3] && report.badge == 3)
    }

    @Test @MainActor func silentPushSkipsAPushedQuestion() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        let withQuestions = QuestionConnection(base: rig.connection, questions: [
            Self.questionJSON("q1", Base.key(1)), Self.questionJSON("q2", Base.key(1)),
        ])
        let trigger = PushedTargets(questions: ["\(rig.profile.id.uuidString)|q1"])
        let posts = rig.posts
        let refresh = BackgroundRefresh(
            profiles: { [profile = rig.profile] in [profile] }, connector: QuestionConnector(connection: withQuestions),
            cursors: rig.cursors, defaults: rig.defaults, post: { posts.batches.append($0) }, setBadge: { _ in },
            delivered: { [] })
        _ = await refresh.run(trigger: .silentPush(trigger))
        #expect(rig.posts.identifiers == ["question:q2"])
        #expect(rig.cursors.cursor(for: rig.profile.id)?.questionIds.sorted() == ["q1", "q2"])
    }

    @Test @MainActor func silentPushWithNothingPushedPostsEverythingNew() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        rig.connection.sessions = [Base.row(Base.key(1), activity: 2000)]
        let report = await Self.refresher(rig).run(trigger: .silentPush(PushedTargets()))
        #expect(report.posted == 1 && rig.posts.identifiers == ["reply:\(Base.key(1)):2000"])
    }

    // MARK: SilentPushRefresh

    @MainActor
    final class Completions {
        var results: [SilentPushRefresh.Result] = []
    }

    static func payload(gatewayId: UUID, keys: WebPushKeys, json: String) -> [AnyHashable: Any] {
        let body = try! WebPush.encrypt(Data(json.utf8), p256dh: Data(base64URL: keys.p256dh)!, auth: keys.authSecret)
        return ["aps": ["content-available": 1], "pincer": ["g": gatewayId.uuidString, "p": body.base64URL]]
    }

    @MainActor
    static func wait(_ completions: Completions, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while completions.results.isEmpty, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor
    static func silent(_ rig: Base.Rig, userInfo: [AnyHashable: Any] = ["pincer": ["g": UUID().uuidString, "p": "x"]],
                       refresh: BackgroundRefresh, deadline: TimeInterval = 25,
                       timer: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                       completions: Completions) -> SilentPushRefresh {
        SilentPushRefresh(userInfo: userInfo, refresh: refresh, budget: 25, deadline: deadline, keys: { _ in nil },
                          timer: timer) { completions.results.append($0) }
    }

    @Test @MainActor func newDataCompletesOnceAndDedupesTheTriggeringPush() async throws {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        rig.connection.sessions = [Base.row(Base.key(1), activity: 2000), Base.row("agent:main:main", activity: 3000)]
        let keys = WebPushKeys.generate()
        let info = Self.payload(gatewayId: rig.profile.id, keys: keys, json: #"{"title":"Claw","body":"Done","url":"chat/main"}"#)
        let completions = Completions()
        let refresh = Self.refresher(rig, timer: BudgetGate().timer)
        SilentPushRefresh(userInfo: info, refresh: refresh, budget: 25, deadline: 25, keys: { _ in keys },
                          timer: BudgetGate().timer) { completions.results.append($0) }.start()
        await Self.wait(completions)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completions.results == [.newData])
        #expect(rig.posts.identifiers == ["reply:\(Base.key(1)):2000"], "the pushed main chat isn't posted again")
    }

    typealias BudgetGate = Base.BudgetGate

    @Test @MainActor func nothingNewIsNoData() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        let completions = Completions()
        Self.silent(rig, refresh: Self.refresher(rig), timer: BudgetGate().timer, completions: completions).start()
        await Self.wait(completions)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completions.results == [.noData])
    }

    @Test @MainActor func undecodablePushStillRefreshes() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        rig.connection.sessions = [Base.row(Base.key(1), activity: 2000)]
        let completions = Completions()
        Self.silent(rig, userInfo: ["aps": ["alert": "x"]], refresh: Self.refresher(rig), timer: BudgetGate().timer,
                    completions: completions).start()
        await Self.wait(completions)
        #expect(completions.results == [.newData])
        #expect(rig.posts.identifiers == ["reply:\(Base.key(1)):2000"])
    }

    @Test @MainActor func skippedRunIsNoData() async {
        let rig = Base.Rig(mode: .backgroundRefresh)
        let completions = Completions()
        Self.silent(rig, refresh: Self.refresher(rig), timer: BudgetGate().timer, completions: completions).start()
        await Self.wait(completions)
        #expect(completions.results == [.noData])
        #expect(rig.connection.methods.isEmpty)
    }

    @Test @MainActor func unreachableGatewayIsFailed() async {
        let rig = Base.Rig(mode: .pushRelay)
        let completions = Completions()
        Self.silent(rig, refresh: Self.refresher(rig, unreachable: true), timer: BudgetGate().timer, completions: completions).start()
        await Self.wait(completions)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completions.results == [.failed])
    }

    @Test @MainActor func deadlineCompletesFailedOnceEvenIfWorkFinishesLater() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.cursors.save(Base.base, for: rig.profile.id)
        rig.connection.delay = .milliseconds(300)
        rig.connection.sessions = [Base.row(Base.key(1), activity: 2000)]
        let deadlineGate = BudgetGate()
        let completions = Completions()
        // The refresh's own budget never ends, so only the watchdog can stop it.
        Self.silent(rig, refresh: Self.refresher(rig, timer: BudgetGate().timer), deadline: 25,
                    timer: deadlineGate.timer, completions: completions).start()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completions.results.isEmpty)
        deadlineGate.expire()
        await Self.wait(completions)
        #expect(completions.results == [.failed])
        try? await Task.sleep(for: .milliseconds(700))
        #expect(completions.results == [.failed], "late work doesn't complete a second time")
    }

    @Test @MainActor func deadlineFiresEvenWhenTheGatewayHangs() async {
        let rig = Base.Rig(mode: .pushRelay)
        rig.connection.delay = .seconds(3600)
        let deadlineGate = BudgetGate()
        let completions = Completions()
        Self.silent(rig, refresh: Self.refresher(rig, timer: BudgetGate().timer), timer: deadlineGate.timer,
                    completions: completions).start()
        try? await Task.sleep(for: .milliseconds(50))
        deadlineGate.expire()
        await Self.wait(completions)
        #expect(completions.results == [.failed])
    }

    @Test @MainActor func deadlineIsInsideTheSystemWindowAndAfterTheBudget() {
        #expect(SilentPushRefresh.deadline <= 28)
        #expect(SilentPushRefresh.deadline > SilentPushRefresh.budget)
        #expect(SilentPushRefresh.budget <= BackgroundRefresh.defaultBudget)
    }

    // MARK: shouldHandle

    @Test func shouldHandleCases() {
        let defaults = Base.defaults()
        ClosedAppDelivery.set(.pushRelay, defaults)
        defaults.set(true, forKey: "pincer.notifications")
        let pincer: [AnyHashable: Any] = ["aps": ["content-available": 1], "pincer": ["g": UUID().uuidString, "p": "x"]]
        #expect(SilentPushRefresh.shouldHandle(pincer, appIsActive: false, defaults: defaults))
        #expect(!SilentPushRefresh.shouldHandle(["aps": ["content-available": 1]], appIsActive: false, defaults: defaults))
        #expect(!SilentPushRefresh.shouldHandle([:], appIsActive: false, defaults: defaults))
        #expect(!SilentPushRefresh.shouldHandle(pincer, appIsActive: true, defaults: defaults))
        defaults.set(false, forKey: "pincer.notifications")
        #expect(!SilentPushRefresh.shouldHandle(pincer, appIsActive: false, defaults: defaults))
        defaults.set(true, forKey: "pincer.notifications")
        for mode in [ClosedAppDelivery.backgroundRefresh, .off] {
            ClosedAppDelivery.set(mode, defaults)
            #expect(!SilentPushRefresh.shouldHandle(pincer, appIsActive: false, defaults: defaults))
        }
    }
}
