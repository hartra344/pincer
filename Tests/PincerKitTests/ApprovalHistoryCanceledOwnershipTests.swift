import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Approval history canceled publication", .timeLimit(.minutes(2)))
struct ApprovalHistoryCanceledOwnershipTests {
    @MainActor final class Gate {
        var rounds = 0, held: [Int: CheckedContinuation<Void, Never>] = [:]
        var released: Set<Int> = []
        let error: Bool
        init(error: Bool) { self.error = error }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            rounds += 1; let round = rounds
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(round) { continuation.resume() } else { held[round] = continuation }
                }
            } onCancel: { Task { @MainActor in self.release(round) } }
            if error && round == 1 { throw GatewayError.rpc(code: "UNAVAILABLE", message: "old ledger error", details: nil) }
            return ["items": []]
        }
        func release(_ round: Int) { released.insert(round); held.removeValue(forKey: round)?.resume() }
        func wait(_ round: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while held[round] == nil { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        }
    }
    @Test(arguments: [false, true])
    func canceledAdmittedResponseCannotPublish(error: Bool) async throws {
        let gate = Gate(error: error), model = ApprovalHistoryModel(request: gate.request)
        let task = Task { await model.load() }
        defer { task.cancel(); gate.release(1) }
        try await gate.wait(1)
        task.cancel(); gate.release(1); await task.value
        #expect(!model.hasLoaded && model.loadState == .idle && model.supported)
    }
    @Test func oldCancellationCannotIdleNewerLoad() async throws {
        let gate = Gate(error: true), model = ApprovalHistoryModel(request: gate.request)
        let old = Task { await model.load() }
        defer { old.cancel(); gate.release(1); gate.release(2) }
        try await gate.wait(1)
        let newer = Task { await model.load() }
        defer { newer.cancel(); gate.release(2) }
        try await gate.wait(2)
        old.cancel(); gate.release(1); await old.value
        #expect(model.loadState == .running && !model.hasLoaded)
        gate.release(2); await newer.value
        #expect(model.loadState == .idle && model.hasLoaded)
    }
    @Test func advertisedUnsupportedKeepsExistingBehavior() async {
        var calls = 0
        let model = ApprovalHistoryModel(methods: { ["health"] }) { _, _ in calls += 1; return .null }
        await model.load()
        #expect(calls == 0 && !model.supported)
    }
}
