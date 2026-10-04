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
    @MainActor private final class RoundGate {
        var healthCalls = 0
        var held: [Int: CheckedContinuation<Void, Never>] = [:]
        var released: Set<Int> = []
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            guard method == "health" else { return .null }
            healthCalls += 1
            let round = healthCalls
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(round) { continuation.resume() } else { held[round] = continuation }
                }
            } onCancel: { Task { @MainActor in self.release(round) } }
            if round == 1 { throw GatewayError.rpc(code: "FAILED", message: "canceled old failure", details: nil) }
            return ["ok": true, "ts": 1700000000000, "channels": [:]]
        }
        func release(_ round: Int) { released.insert(round); held.removeValue(forKey: round)?.resume() }
    }
    @Test func canceledOldErrorCannotFailOrIdleNewerRunningLoad() async throws {
        let gate = RoundGate(), model = GatewayHealthModel(request: gate.request)
        let old = Task { await model.load() }
        defer { old.cancel(); gate.release(1); gate.release(2) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while gate.held[1] == nil { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        let newer = Task { await model.load() }
        defer { newer.cancel(); gate.release(2) }
        while gate.held[2] == nil { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        old.cancel(); gate.release(1); await old.value
        #expect(model.loadState == .running && !model.hasLoaded && model.health == nil)
        gate.release(2); await newer.value
        #expect(model.loadState == .idle && model.hasLoaded && model.health != nil)
    }
    @Test func canceledCurrentErrorCannotPublishFailure() async throws {
        let gate = RoundGate(), model = GatewayHealthModel(request: gate.request)
        let task = Task { await model.load() }
        defer { task.cancel(); gate.release(1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while gate.held[1] == nil { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        task.cancel(); gate.release(1); await task.value
        #expect(model.loadState == .idle && !model.hasLoaded && model.health == nil)
    }

}
