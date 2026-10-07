import Foundation
import Testing
@testable import PincerKit

/// #294: a burst of silent pushes runs one refresh at a time.
@Suite("Silent push refresh runs")
struct SilentPushRefreshRunsTests {
    struct HangingConnector: IntentConnector {
        func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }

        func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
        func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
    }

    @MainActor
    final class Results {
        var values: [SilentPushRefresh.Result] = []
        var made = 0
    }

    static var push: [AnyHashable: Any] {  ["pincer": ["g": UUID().uuidString, "p": "x"]] }

    @MainActor
    static func make(_ results: Results, defaults: UserDefaults, deadline: TimeInterval = 0.3)
        -> (_ userInfo: [AnyHashable: Any], _ completion: @escaping @MainActor (SilentPushRefresh.Result) -> Void) -> SilentPushRefresh
    {
        { userInfo, completion in
            results.made += 1
            let refresh = BackgroundRefresh(
                profiles: { [GatewayProfile(name: "Hang", url: "ws://127.0.0.1:1", authMode: .none)] }, connector: HangingConnector(),
                defaults: defaults, post: { _ in }, setBadge: { _ in }, delivered: { [] })
            return SilentPushRefresh(userInfo: userInfo, refresh: refresh, budget: 5, deadline: deadline,
                                     keys: { _ in nil }, completion: completion)
        }
    }

    @MainActor
    static func wait(_ results: Results, count: Int) async {
        let end = Date().addingTimeInterval(5)
        while results.values.count < count, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    @Test func secondPushWhileOneIsInFlightIsNoDataAtOnceAndAfterwardsANewRunStarts() async {
        let defaults = BackgroundRefreshTests.defaults()
        ClosedAppDelivery.set(.pushRelay, defaults)
        let runs = SilentPushRefreshRuns()
        let results = Results()
        let make = Self.make(results, defaults: defaults)

        runs.handle(Self.push, appIsActive: false, defaults: defaults, make: make) { results.values.append($0) }
        #expect(runs.isRunning && results.made == 1 && results.values.isEmpty)

        var second: [SilentPushRefresh.Result] = []
        runs.handle(Self.push, appIsActive: false, defaults: defaults, make: make) { second.append($0) }
        #expect(second == [.noData] && results.made == 1)

        await Self.wait(results, count: 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(results.values == [.failed], "the first run completes exactly once")
        #expect(!runs.isRunning)

        runs.handle(Self.push, appIsActive: false, defaults: defaults, make: make) { results.values.append($0) }
        #expect(results.made == 2 && runs.isRunning)
        await Self.wait(results, count: 2)
        #expect(results.values == [.failed, .failed])
    }

    @MainActor
    @Test func pushesThatAreNotHandledAnswerNoDataWithoutStartingARun() {
        let defaults = BackgroundRefreshTests.defaults()
        ClosedAppDelivery.set(.pushRelay, defaults)
        let runs = SilentPushRefreshRuns()
        let results = Results()
        let make = Self.make(results, defaults: defaults)
        var answers: [SilentPushRefresh.Result] = []
        runs.handle(Self.push, appIsActive: true, defaults: defaults, make: make) { answers.append($0) }
        runs.handle(["aps": ["alert": "x"]], appIsActive: false, defaults: defaults, make: make) { answers.append($0) }
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        runs.handle(Self.push, appIsActive: false, defaults: defaults, make: make) { answers.append($0) }
        #expect(answers == [.noData, .noData, .noData] && results.made == 0 && !runs.isRunning)
    }
}
