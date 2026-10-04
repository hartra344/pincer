import Foundation
@testable import PincerKit

@MainActor private final class ApprovalAdmissionGate {
    var entered = false, open = false
    var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in if open || Task.isCancelled { continuation.resume() } else { held = continuation } }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor private func checkApprovalCanceledAdmission(_ request: @escaping ApprovalHistoryModel.Request) async {
    let gate = ApprovalAdmissionGate()
    var attempts = 0, page: JSONValue = .null
    let model = ApprovalHistoryModel { method, params in
        attempts += 1
        check(method == "approval.history" && params == ["limit": 50], "approval history exact read-only request")
        try Task.checkCancellation()
        let value = try await request(method, params)
        page = value
        await gate.hold()
        return value
    }
    let healthy = Task { await model.load() }
    defer { healthy.cancel(); gate.release() }
    guard await waitFor("actual held approval history", timeout: 15, { gate.entered }) else {
        check(false, "approval history reaches actual held response"); healthy.cancel(); gate.release(); await healthy.value; return
    }
    guard let raw = page["items"]?.array, !raw.isEmpty else {
        check(false, "actual held ledger page contains seeded terminal records")
        healthy.cancel(); gate.release(); await healthy.value; return
    }
    let expected = raw.compactMap(ApprovalRecord.init)
    guard expected.count == raw.count, expected.allSatisfy({ $0.status != .pending }) else {
        check(false, "all actual held ledger records decode completely and are terminal")
        healthy.cancel(); gate.release(); await healthy.value; return
    }
    check(true, "actual held page has fully decoded nonempty terminal records")
    let canceled = Task { await model.load() }; canceled.cancel(); await canceled.value
    gate.release(); await healthy.value
    check(attempts == 1, "pre-canceled load admits no second ledger request")
    check(model.items == expected, "full actual terminal records survive canceled admission")
    check(model.nextCursor == page["nextCursor"]?.string && model.hasLoaded && model.loadState == .idle, "actual cursor and terminal load state survive canceled admission")
}
@MainActor func runApprovalHistoryCanceledAdmissionChecks() async {
    await checkApprovalCanceledAdmission { _, _ in ["items": [["id": "terminal-one", "presentation": ["kind": "exec", "commandText": "echo fixture", "allowedDecisions": ["allow-once", "deny"]], "urlPath": "/approve/terminal-one", "expiresAtMs": 1700000002000, "reason": "user", "status": "denied", "decision": "deny", "createdAtMs": 1700000000000, "resolvedAtMs": 1700000001000]], "nextCursor": "opaque-next"] }
}
@MainActor func runDemoApprovalHistoryCanceledAdmissionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("approval history Demo", timeout: 25, { gateway.state.isConnected }) else { check(false, "actual Demo connects"); return }
    await checkApprovalCanceledAdmission { method, params in try await gateway.connection.request(method, params, timeout: 30) }
}
