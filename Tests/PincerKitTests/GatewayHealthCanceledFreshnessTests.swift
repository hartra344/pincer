import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Health cancellation freshness", .timeLimit(.minutes(2)))
struct GatewayHealthCanceledFreshnessTests {
    @Test func canceledRefreshDoesNotConsumeStalenessWindow() async {
        var calls = 0
        let model = GatewayHealthModel { method, _ in
            calls += 1
            if method == "health" { return ["ok": true, "ts": 1700000000000, "channels": [:]] }
            return .null
        }
        let now = Date(timeIntervalSince1970: 1700000000)
        let canceled = Task { await model.refresh(now: now) }
        canceled.cancel(); await canceled.value
        #expect(calls == 0)
        await model.refreshIfStale(now: now)
        #expect(calls == 2 && model.health != nil)
        await model.refreshIfStale(now: now)
        #expect(calls == 2)
    }
    @Test func canceledAdmittedLoadCannotPublishOrStrandRunningState() async throws {
        let fixture = GatewayHealthCanceledAdmissionTests.Fixture()
        let model = GatewayHealthModel(request: fixture.request)
        let task = Task { await model.load() }
        defer { task.cancel(); fixture.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !fixture.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        task.cancel(); fixture.release(); await task.value
        #expect(model.health == nil && !model.hasLoaded && model.loadState == .idle)
        // The same owner can be refreshed normally after canceled work settles.
        await model.load()
        #expect(model.health != nil && model.hasLoaded && model.loadState == .idle)
    }
}
