import Foundation
import Testing
@testable import PincerKit

@MainActor private final class ExecReloadGate {
    var entered = false, open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { if open || Task.isCancelled { $0.resume() } else { continuation = $0 } }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ExecPolicyReloadEditOwnershipTests {
    // Official get params/snapshot at 65bfe17569ccebd50ee158b4a9a8285c940f1d93.
    @Test(arguments: ["aba", "edit", "none"])
    func actualReloadPreservesEditsAdmittedAfterRead(mode: String) async throws {
        let initial: JSONValue = ["path": "policy.json", "exists": true, "hash": "initial", "file": ["version": 1, "defaults": ["ask": "on-miss"]]]
        let returned: JSONValue = ["path": "policy.json", "exists": true, "hash": "current", "file": ["version": 1, "defaults": ["ask": "off"]]]
        let gate = ExecReloadGate()
        var calls = 0
        let model = ExecPolicyModel { method, params in
            #expect(method == ExecPolicy.getMethod && params == [:])
            calls += 1
            if calls == 1 { return initial }
            await gate.hold(); return returned
        }
        await model.load()
        try #require(model.snapshot == ExecApprovalsSnapshot(initial))
        let originalAsk = model.savedValue(.ask, agent: nil)
        let admittedDraft = model.draft
        let task = Task { await model.load() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !gate.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        } catch { task.cancel(); gate.release(); await task.value; throw error }
        if mode != "none" { model.set(.ask, "always", agent: nil) }
        if mode == "aba" { model.set(.ask, originalAsk, agent: nil) }
        let expected = mode == "none" ? ExecApprovalsSnapshot(returned).file : model.draft
        if mode == "aba" { #expect(model.draft == admittedDraft) }
        gate.release(); await task.value
        #expect(calls == 2 && model.draft == expected)
        #expect(model.snapshot == ExecApprovalsSnapshot(mode == "none" ? returned : initial))
        #expect(model.loadState == .idle && model.hasLoaded)
    }
}
