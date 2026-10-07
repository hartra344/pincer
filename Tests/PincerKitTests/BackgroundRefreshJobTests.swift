import Foundation
import Testing
@testable import PincerKit

/// #930: iOS calls a `BGTask`'s expiration handler on a background queue. The handler asserted the
/// main actor and trapped whenever a refresh outlived its time, e.g. with the Gateway down.
@Suite("Background refresh job")
struct BackgroundRefreshJobTests {
    @MainActor
    final class Completions {
        var values: [Bool] = []
    }

    /// The system's expiration callback, from a non-main thread as iOS delivers it.
    static func expireOffMain(_ job: BackgroundRefreshJob) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                #expect(!Thread.isMainThread)
                job.expire()
                done.resume()
            }
        }
    }

    @MainActor
    static func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock(), end = clock.now + timeout
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test @MainActor func expiringOffMainCompletesOnceWithoutTrapping() async {
        let completions = Completions()
        let job = BackgroundRefreshJob(
            work: {
                try? await Task.sleep(for: .seconds(3600))
                return true
            },
            complete: { completions.values.append($0) })
        job.start()
        await Self.expireOffMain(job)
        #expect(await Self.eventually { !completions.values.isEmpty })
        #expect(completions.values == [false])
        // The cancelled work unwinding afterwards doesn't complete the task a second time.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(completions.values == [false] && job.finished)
    }

    @Test @MainActor func finishedWorkCompletesOnceAndLateExpiryIsIgnored() async {
        let completions = Completions()
        let job = BackgroundRefreshJob(work: { true }, complete: { completions.values.append($0) })
        job.start()
        #expect(await Self.eventually { !completions.values.isEmpty })
        await Self.expireOffMain(job)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(completions.values == [true])
    }

    @Test @MainActor func failedRunCompletesUnsuccessfully() async {
        let completions = Completions()
        let job = BackgroundRefreshJob(work: { false }, complete: { completions.values.append($0) })
        job.start()
        #expect(await Self.eventually { !completions.values.isEmpty })
        #expect(completions.values == [false])
    }

    @Test func mainHopRunsOnMainFromBackground() async {
        let ranOnMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                MainHop.run { done.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(ranOnMain)
    }

    @Test @MainActor func mainHopRunsInlineOnMain() {
        var ran = false
        MainHop.run { ran = true }
        #expect(ran)
    }

    // MARK: Budget

    @MainActor
    struct HangingConnector: IntentConnector {
        func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
            try await Task.sleep(for: .seconds(3600))
            throw IntentError.unreachable(gateway: profile.name)
        }

        func liveTargets(_ gatewayId: UUID) -> GatewayTargets? { nil }
        func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? { nil }
    }

    @Test @MainActor func defaultBudgetLeavesHeadroomInTheSystemWindow() {
        // iOS gives a refresh about 30 s from launch; the run must end well before expiration.
        #expect(BackgroundRefresh.defaultBudget <= 20)
    }

    @Test @MainActor func unreachableGatewaysEndTheRunWithinBudget() async {
        let suite = "pincer.tests.refresh-job.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        defaults.set(true, forKey: "pincer.notifications")
        let profiles = (0..<3).map { GatewayProfile(name: "Down \($0)", url: "wss://down\($0).example", authMode: .token) }
        let refresh = BackgroundRefresh(
            profiles: { profiles }, connector: HangingConnector(),
            cursors: BackgroundRefreshCursorStore(defaults: defaults), defaults: defaults,
            post: { _ in }, setBadge: { _ in })
        let clock = ContinuousClock(), start = clock.now
        let report = await refresh.run(budget: 0.3)
        #expect(clock.now - start < .seconds(3))
        #expect(Set(report.aborted) == Set(profiles.map(\.id)) && report.badge == nil)
    }
}
