import Foundation
@testable import PincerKit

@MainActor private final class ExecPolicyReloadDeliveryGate {
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

@MainActor private func checkExecReloadEdits(request: @escaping ExecPolicyModel.Request,
    changeIsolatedPolicy: ((ExecApprovalsSnapshot) async throws -> Void)? = nil) async {
    for mode in ["aba", "edit", "none"] {
        let gate = ExecPolicyReloadDeliveryGate()
        var calls = 0, delivered: JSONValue = .null
        let model = ExecPolicyModel { method, params in
            calls += 1
            check(method == ExecPolicy.getMethod && params == [:], "reload uses the actual read-only exec approvals request")
            let result = try await request(method, params)
            if calls == 2 { delivered = result; await gate.hold() }
            return result
        }
        await model.load()
        guard let initial = model.snapshot, initial.exists, let hash = initial.hash, !hash.isEmpty else {
            check(false, "initial actual policy snapshot is loaded"); return
        }
        if let changeIsolatedPolicy {
            do { try await changeIsolatedPolicy(initial) }
            catch { check(false, "isolated Demo policy update succeeds before held reload"); return }
        }
        let localA = model.savedValue(.ask, agent: nil)
        let localB: JSONValue = localA == "always" ? "off" : "always"
        let admittedDraft = model.draft
        let task = Task { await model.load() }
        let entered = await waitFor("actual exec policy reload delivery", timeout: 15) { gate.entered }
        check(entered, "actual computed policy reply reaches the delivery hold")
        guard entered else { task.cancel(); gate.release(); await task.value; return }
        guard delivered["file"]?.object != nil, delivered["hash"]?.text != nil,
              delivered["path"]?.text != nil, delivered["exists"]?.bool != nil else {
            check(false, "held actual reply contains the legal full snapshot")
            task.cancel(); gate.release(); await task.value; return
        }
        if changeIsolatedPolicy != nil {
            let different = ExecApprovalsSnapshot(delivered).file != initial.file
            check(different, "actual returned Demo policy C differs from admitted baseline A")
            guard different else { gate.release(); await task.value; return }
        }
        if mode != "none" { model.set(.ask, localB, agent: nil) }
        if mode == "aba" { model.set(.ask, localA, agent: nil) }
        let expected = mode == "none" ? ExecApprovalsSnapshot(delivered).file : model.draft
        if mode == "aba" { check(model.draft == admittedDraft, "actual mutators return to the admitted A draft before delivery") }
        gate.release(); await task.value
        check(calls == 2 && model.draft == expected, "actual reload retains exact post-admission \(mode) intent")
        check(model.snapshot == (mode == "none" ? ExecApprovalsSnapshot(delivered) : initial),
              "reload keeps the correct draft baseline and full policy snapshot")
        check(model.hasLoaded && model.loadState == .idle, "actual reload completes healthy after delivery")
    }
}

@MainActor func runExecPolicyReloadEditOwnershipChecks() async {
    var calls = 0
    await checkExecReloadEdits(request: { _, _ in
        calls += 1
        return ["path": "policy.json", "exists": true, "hash": .string(calls.isMultiple(of: 2) ? "current" : "initial"),
                "file": ["version": 1, "defaults": ["ask": .string(calls.isMultiple(of: 2) ? "off" : "on-miss")]]]
    })
}

@MainActor func runDemoExecPolicyReloadEditOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("actual exec policy reload Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "genuine Demo policy read connection is ready")
    guard ready else { return }
    let read: ExecPolicyModel.Request = { method, params in try await gateway.connection.request(method, params, timeout: 30) }
    await checkExecReloadEdits(request: read) // Unchanged-server ordinary source coverage.
    await checkExecReloadEdits(request: read, changeIsolatedPolicy: { snapshot in
        // Only this isolated built-in Demo is mutated; no response overlays or real Gateway writes.
        var changed = snapshot.file
        let next: JSONValue = snapshot.file.value(.ask, agent: nil) == "always" ? "off" : "always"
        changed.set(.ask, next, agent: nil)
        let result = try await gateway.connection.request(ExecPolicy.setMethod, ExecPolicy.setParams(draft: changed, snapshot: snapshot), timeout: 30)
        guard result["file"]?.object != nil, ExecApprovalsSnapshot(result).file == changed else {
            throw NSError(domain: "IsolatedDemoPolicySetup", code: 1)
        }
    })
}
