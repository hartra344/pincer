import Foundation
import Testing
@testable import PincerKit

@MainActor private final class ExecRevisionGate {
    var entered = false
    private var held: CheckedContinuation<Void, Never>?
    private var open = false
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { if open || Task.isCancelled { $0.resume() } else { held = $0 } }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { open = true; held?.resume(); held = nil }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ExecPolicyReloadEditRevisionTests {
    @Test(arguments: ["no-op", "revert", "discard"])
    func explicitIntentAndDiscardHaveDistinctReloadAuthority(mode: String) async throws {
        let initial: JSONValue = ["path": "policy.json", "exists": true, "hash": "old", "file": ["version": 1, "defaults": ["ask": "on-miss"]]]
        let current: JSONValue = ["path": "policy.json", "exists": true, "hash": "new", "file": ["version": 1, "defaults": ["ask": "off"]]]
        let gate = ExecRevisionGate()
        var calls = 0
        let model = ExecPolicyModel { _, _ in
            calls += 1
            if calls == 1 { return initial }
            await gate.hold(); return current
        }
        await model.load()
        try #require(model.snapshot == ExecApprovalsSnapshot(initial))
        let task = Task { await model.load(discardingDraft: mode == "discard") }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !gate.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        } catch { task.cancel(); gate.release(); await task.value; throw error }
        if mode == "revert" { model.set(.ask, "always", agent: nil); model.revert() }
        else { model.set(.ask, "on-miss", agent: nil) }
        gate.release(); await task.value
        let expected = ExecApprovalsSnapshot(mode == "discard" ? current : initial)
        #expect(model.snapshot == expected && model.draft == expected.file)
        #expect(calls == 2 && model.hasLoaded && model.loadState == .idle)
    }
}
