import Foundation
import PincerKit

@MainActor private final class ExecRevisionCheckGate {
    var entered = false, open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { if open || Task.isCancelled { $0.resume() } else { held = $0 } }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor func runExecPolicyReloadRevisionChecks() async {
    for mode in ["no-op", "revert", "discard"] {
        let old: JSONValue = ["path": "policy.json", "exists": true, "hash": "old", "file": ["version": 1, "defaults": ["ask": "on-miss"]]]
        let fresh: JSONValue = ["path": "policy.json", "exists": true, "hash": "fresh", "file": ["version": 1, "defaults": ["ask": "off"]]]
        let gate = ExecRevisionCheckGate()
        var calls = 0
        let model = ExecPolicyModel { _, _ in calls += 1; if calls == 1 { return old }; await gate.hold(); return fresh }
        await model.load()
        check(model.snapshot == ExecApprovalsSnapshot(old), "revision control loads exact initial policy")
        guard model.snapshot == ExecApprovalsSnapshot(old) else { return }
        let task = Task { await model.load(discardingDraft: mode == "discard") }
        let entered = await waitFor("actual revision control policy read", timeout: 15) { gate.entered }
        check(entered, "revision control reaches actual held read")
        guard entered else { task.cancel(); gate.release(); await task.value; return }
        if mode == "revert" { model.set(.ask, "always", agent: nil); model.revert() }
        else { model.set(.ask, "on-miss", agent: nil) }
        gate.release(); await task.value
        let expected = ExecApprovalsSnapshot(mode == "discard" ? fresh : old)
        check(model.snapshot == expected && model.draft == expected.file, "exact \(mode) reload authority is retained")
        check(calls == 2 && model.hasLoaded && model.loadState == .idle, "revision control completes actual healthy read")
    }
}
