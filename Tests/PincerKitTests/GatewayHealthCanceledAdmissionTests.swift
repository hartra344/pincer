import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Health canceled admission", .timeLimit(.minutes(2)))
struct GatewayHealthCanceledAdmissionTests {
    @MainActor final class Fixture {
        var entered = false, released = false, calls = 0
        var waiter: CheckedContinuation<Void, Never>?
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            try Task.checkCancellation()
            calls += 1
            if method == "health" {
                entered = true
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if released { continuation.resume() } else { waiter = continuation }
                    }
                } onCancel: { Task { @MainActor in self.release() } }
                return ["ok": true, "ts": 1700000000000, "channels": [:]]
            }
            if method == "last-heartbeat" { return ["ts": 1700000000000, "status": "ok"] }
            return []
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }
    @Test(arguments: [false, true])
    func preCanceledAdmissionCannotDiscardHealthyLoad(refresh: Bool) async throws {
        let fixture = Fixture(), model = GatewayHealthModel(request: fixture.request)
        let healthy = Task { await model.load() }
        defer { healthy.cancel(); fixture.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !fixture.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        let canceled = Task { if refresh { await model.refresh() } else { await model.load() } }
        canceled.cancel()
        await canceled.value
        fixture.release()
        await healthy.value
        #expect(fixture.calls == 3)
        #expect(model.health != nil && model.heartbeatLoaded && model.hasLoaded)
        #expect(model.loadState == .idle)
    }
    @Test func ordinaryLoadAndCurrentErrorRetainSemantics() async {
        let healthy = GatewayHealthModel { method, _ in
            if method == "health" { return ["ok": true, "ts": 1700000000000, "channels": [:]] }
            return .null
        }
        await healthy.load()
        #expect(healthy.health != nil && healthy.hasLoaded && healthy.loadState == .idle)
        let failed = GatewayHealthModel { _, _ in throw GatewayError.rpc(code: "FAILED", message: "current failure", details: nil) }
        await failed.load()
        #expect(failed.loadState == .failed("current failure") && failed.hasLoaded)
    }
}
