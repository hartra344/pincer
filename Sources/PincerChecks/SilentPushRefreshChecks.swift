import Foundation
import PincerKit
import PincerPush
import UserNotifications

// #294: a content-available push wakes the app for ~30 s. The wake completes exactly once and
// inside its deadline whatever the gateway does, and never repeats what a push already showed.

@MainActor
private final class Outcomes {
    var results: [SilentPushRefresh.Result] = []
}

@MainActor
private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
}

/// A silent-push run against a gateway that is down, timed.
@MainActor
private func runSilentPush(against profile: GatewayProfile, defaults: UserDefaults, budget: TimeInterval, deadline: TimeInterval)
    async -> (results: [SilentPushRefresh.Result], elapsed: Duration)
{
    let outcomes = Outcomes()
    let refresh = BackgroundRefresh(
        profiles: { [profile] }, connector: GatewayIntentConnector(identity: { DeviceIdentity.loadOrCreate() }),
        cursors: BackgroundRefreshCursorStore(defaults: defaults), defaults: defaults,
        post: { _ in }, setBadge: { _ in }, delivered: { [] })
    let clock = ContinuousClock(), start = clock.now
    SilentPushRefresh(userInfo: ["pincer": ["g": profile.id.uuidString, "p": "x"]], refresh: refresh, budget: budget,
                      deadline: deadline, keys: { _ in nil }, completion: { outcomes.results.append($0) }).start()
    await waitUntil(deadline + 5) { !outcomes.results.isEmpty }
    let elapsed = clock.now - start
    // A late second completion would show up here.
    try? await Task.sleep(for: .milliseconds(500))
    return (outcomes.results, elapsed)
}

@MainActor
func runSilentPushRefreshChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    ClosedAppDelivery.set(.pushRelay, defaults)
    defaults.set(true, forKey: "pincer.notifications")

    guard let hang = DownGateway(.hang), let gone = DownGateway(.hangUp) else { return check(false, "down gateways listening") }
    let refusedPort = gone.port
    gone.stop()
    defer { hang.stop() }

    let budget: TimeInterval = 1.5, deadline: TimeInterval = 3
    let slack = Duration.seconds(deadline + 1)
    for (label, port) in [("refused", refusedPort), ("hanging", hang.port)] {
        let profile = GatewayProfile(name: label, url: "ws://127.0.0.1:\(port)", authMode: .none)
        let run = await runSilentPush(against: profile, defaults: defaults, budget: budget, deadline: deadline)
        check(run.results == [.failed], "\(label) gateway: silent push completes exactly once as failed (\(run.results))")
        check(run.elapsed < slack, "\(label) gateway: silent push completes within the deadline (\(run.elapsed))")
    }

    checkSilentPushDedupe()
    await checkSilentPushDedupeRun()
}

@MainActor
private func checkSilentPushDedupe() {
    let gid = UUID()
    let id = gid.uuidString
    func request(_ identifier: String, _ info: [String: String]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = info
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
    let targets = PushedTargets(sessions: ["\(id)|s1"], approvals: ["\(id)|a1"])
    check(targets.covers(request("reply:s1:1", ["gateway": id.lowercased(), "session": "s1"])), "a pushed chat covers its reply")
    check(!targets.covers(request("reply:s2:1", ["gateway": id, "session": "s2"])), "another chat isn't covered")
    check(targets.covers(request("approval:a1", ["gateway": id, "approval": "a1", "session": "other"])), "approvals match by id")
    check(!targets.covers(request("question:q", ["gateway": id, "session": "s1"])), "a pushed chat doesn't cover a question")
    check(PushedTargets(questions: ["\(id)|q"]).covers(request("question:q", ["gateway": id])), "a pushed question covers itself")
    check(!targets.covers(request("refresh-summary:1:2", ["gateway": id])), "a summary without a chat is never covered")
    check(PushedTargets(userInfos: [["gateway": id, "session": ""], ["gateway": id, "approval": ""]]) == PushedTargets(),
          "empty ids are ignored")
    check(SilentPushRefresh.deadline > SilentPushRefresh.budget && SilentPushRefresh.deadline < 30,
          "the deadline sits after the budget and inside the system's wake")
}

/// The run itself, with fakes: pushed and delivered items aren't posted again; the cursor and badge move on.
@MainActor
private func checkSilentPushDedupeRun() async {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    ClosedAppDelivery.set(.pushRelay, defaults)
    defaults.set(true, forKey: "pincer.notifications")
    let profile = GatewayProfile(name: "Home", url: "wss://home.example", authMode: .token)
    let cursors = BackgroundRefreshCursorStore(defaults: defaults)
    cursors.save(BackgroundRefreshCursor(activityMs: 1000), for: profile.id)

    let connection = DedupeConnection()
    var posted: [String] = []
    var badges: [Int] = []
    let refresh = BackgroundRefresh(
        profiles: { [profile] }, connector: DedupeConnector(connection: connection), cursors: cursors, defaults: defaults,
        post: { posted += $0.map(\.identifier) }, setBadge: { badges.append($0) },
        delivered: { [["gateway": profile.id.uuidString, "approval": "a1", "push": "1"]] })
    let triggering = PushedTargets(sessions: ["\(profile.id.uuidString)|agent:main:dashboard:c2"])
    let report = await refresh.run(budget: 5, trigger: .silentPush(triggering))
    check(Set(posted) == ["reply:agent:main:dashboard:c3:4000", "approval:a2"],
          "only unpushed items are posted (\(posted))")
    check(report.posted == 2 && badges == [2], "posted count and badge reflect the run")
    let cursor = cursors.cursor(for: profile.id)
    check(cursor?.activityMs == 4000 && cursor?.approvalIds.sorted() == ["a1", "a2"], "the cursor covers pushed items too")

    let scheduled = await refresh.run(budget: 5, trigger: .scheduled)
    check(scheduled.skipped, "a scheduled run is skipped in push relay mode")
}

private struct DedupeConnector: IntentConnector {
    let connection: DedupeConnection
    func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection { self.connection }
    func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
    func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
}

private final class DedupeConnection: IntentConnection {
    private static func row(_ n: Int, _ activity: Int) -> JSONValue {
        .object(["key": .string("agent:main:dashboard:c\(n)"), "unread": .bool(true), "lastActivityAt": .number(Double(activity)),
                 "lastMessagePreview": .string("Preview \(n)")])
    }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let expiry = JSONValue.number(Date().timeIntervalSince1970 * 1000 + 600_000)
        switch method {
        case "agents.list": return .object(["defaultId": .string("main"), "agents": .array([.object(["id": .string("main")])])])
        case "sessions.list": return .object(["sessions": .array([Self.row(2, 3000), Self.row(3, 4000)])])
        case "exec.approval.list":
            return .object(["approvals": .array(["a1", "a2"].map {
                .object(["id": .string($0), "request": .object(["command": .string("ls")]), "expiresAtMs": expiry])
            })])
        default: return .object(["questions": .array([])])
        }
    }

    func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int { 0 }
    func stopObserving(_ token: Int) {}
    func close() async {}
}
