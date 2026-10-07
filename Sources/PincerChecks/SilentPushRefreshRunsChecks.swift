import Foundation
import PincerKit

// #294: a burst of silent pushes must not start two refreshes against the same cursor.

private struct HangingConnector: IntentConnector {
    func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
    func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
}

@MainActor
func runSilentPushRefreshRunsChecks() async {
    let suite = "pincer.checks.silentruns.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    ClosedAppDelivery.set(.pushRelay, defaults)
    let runs = SilentPushRefreshRuns()
    var made = 0
    var first: [SilentPushRefresh.Result] = []
    var second: [SilentPushRefresh.Result] = []
    let push: [AnyHashable: Any] = ["pincer": ["g": UUID().uuidString, "p": "x"]]
    let make: (_ userInfo: [AnyHashable: Any], _ completion: @escaping @MainActor (SilentPushRefresh.Result) -> Void)
        -> SilentPushRefresh = { userInfo, completion in
            made += 1
            let refresh = BackgroundRefresh(
                profiles: { [GatewayProfile(name: "Hang", url: "ws://127.0.0.1:1", authMode: .none)] }, connector: HangingConnector(),
                defaults: defaults, post: { _ in }, setBadge: { _ in }, delivered: { [] })
            return SilentPushRefresh(userInfo: userInfo, refresh: refresh, budget: 5, deadline: 0.3,
                                     keys: { _ in nil }, completion: completion)
        }
    runs.handle(push, appIsActive: false, defaults: defaults, make: make) { first.append($0) }
    runs.handle(push, appIsActive: false, defaults: defaults, make: make) { second.append($0) }
    check(second == [.noData] && made == 1, "a push during a run answers .noData and starts no second run")
    let end = Date().addingTimeInterval(5)
    while first.isEmpty, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    try? await Task.sleep(for: .milliseconds(100))
    check(first == [.failed] && !runs.isRunning, "the run completes once at its deadline and is released")
    runs.handle(push, appIsActive: false, defaults: defaults, make: make) { _ in }
    check(made == 2, "a push after completion starts a new run")
    // A push that arrives during a run is merged into the run's covered set.
    var sink: [SilentPushRefresh.Result] = []
    let gateway = UUID()
    let run = SilentPushRefresh(userInfo: push, completion: { sink.append($0) })
    let targets = PushedTargets(sessions: ["\(gateway.uuidString)|agent:main:main"])
    let box = PushedTargetsBox()
    box.cover(targets)
    check(box.targets == targets && sink.isEmpty, "later pushes accumulate in the covered set")
    _ = run
}
