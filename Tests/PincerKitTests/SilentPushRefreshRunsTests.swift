import Foundation
import PincerPush
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

    @MainActor
    final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var reached = false

        func wait() async {
            self.reached = true
            await withCheckedContinuation { self.waiter = $0 }
        }

        func open() { self.waiter?.resume() }
    }

    @MainActor
    @Test func aPushDuringARunIsCoveredAndSilentPushPostsNoSound() async throws {
        let rig = BackgroundRefreshTests.Rig(mode: .pushRelay)
        rig.cursors.save(BackgroundRefreshTests.base, for: rig.profile.id)
        rig.connection.sessions = [
            BackgroundRefreshTests.row(BackgroundRefreshTests.key(1), activity: 2000),
            BackgroundRefreshTests.row("agent:main:main", activity: 3000),
        ]
        let keys = WebPushKeys.generate()
        let later = SilentPushRefreshTests.payload(
            gatewayId: rig.profile.id, keys: keys, json: #"{"title":"Claw","body":"Done","url":"chat/main"}"#)
        let gate = Gate()
        let posts = rig.posts
        let refresh = BackgroundRefresh(
            profiles: { [profile = rig.profile] in [profile] },
            connector: BackgroundRefreshTests.FakeConnector(connections: [rig.profile.id: rig.connection]),
            cursors: rig.cursors, defaults: rig.defaults, post: { posts.batches.append($0) }, setBadge: { _ in },
            delivered: { await gate.wait(); return [] })
        let runs = SilentPushRefreshRuns()
        var results: [SilentPushRefresh.Result] = []
        let first = ["pincer": ["g": rig.profile.id.uuidString, "p": "x"]]
        runs.handle(first, appIsActive: false, defaults: rig.defaults, keys: { _ in keys }, make: { info, done in
            SilentPushRefresh(userInfo: info, refresh: refresh, budget: 25, deadline: 25, keys: { _ in keys }, completion: done)
        }) { results.append($0) }
        let end = Date().addingTimeInterval(5)
        while !gate.reached, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.reached)

        var second: [SilentPushRefresh.Result] = []
        runs.handle(later, appIsActive: false, defaults: rig.defaults, keys: { _ in keys }) { second.append($0) }
        #expect(second == [.noData])
        gate.open()
        while results.isEmpty, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(results == [.newData])
        #expect(posts.identifiers == ["reply:\(BackgroundRefreshTests.key(1)):2000"], "the second push's chat isn't posted")
        #expect(posts.batches.flatMap { $0 }.allSatisfy { $0.content.sound == nil }, "the push already made the sound")
    }
}
