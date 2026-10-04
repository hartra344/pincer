import Foundation
@testable import PincerKit

@MainActor private final class PairingAdmissionGate {
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
private func hasRequiredPairingFields(_ response: JSONValue) -> Bool {
    guard let requests = response["requests"]?.array, let accounts = response["accounts"]?.array,
          !requests.isEmpty, !accounts.isEmpty else { return false }
    let accountKeys = ["channel", "channelLabel", "accountId"]
    let requestKeys = accountKeys + ["requestId", "senderId", "senderLabel", "createdAt", "lastSeenAt", "expiresAt"]
    return accounts.allSatisfy { row in
        accountKeys.allSatisfy { !(row[$0]?.string ?? "").isEmpty } && row["notifySupported"]?.bool != nil
    } && requests.allSatisfy { row in
        requestKeys.allSatisfy { !(row[$0]?.string ?? "").isEmpty } && row["notifySupported"]?.bool != nil
    } && response["commandOwnerConfigured"]?.bool != nil
      && (response["limits"]?["pendingPerAccount"]?.int ?? -1) >= 0
      && (response["limits"]?["ttlMs"]?.double ?? -1) >= 0
}
@MainActor private func checkPairingCanceledAdmission(_ request: @escaping PairingInboxModel.Request) async {
    let gate = PairingAdmissionGate()
    var attempts = 0, response: JSONValue = .null
    let model = PairingInboxModel { method, params in
        attempts += 1
        check(method == PairingInboxModel.listMethod && params == [:], "pairing inbox uses exact read-only list request")
        try Task.checkCancellation()
        let result = try await request(method, params)
        guard hasRequiredPairingFields(result) else {
            check(false, "actual pairing response supplies every required request/account field")
            throw GatewayError.rpc(code: "INVALID_RESPONSE", message: "Incomplete pairing fixture response", details: nil)
        }
        response = result; await gate.hold(); return result
    }
    let task = Task { await model.load() }
    defer { task.cancel(); gate.release() }
    guard await waitFor("held actual pairing inbox", timeout: 15, { gate.entered }) else {
        check(false, "actual pairing read reaches held response"); task.cancel(); gate.release(); await task.value; return
    }
    guard let rawRequests = response["requests"]?.array, let rawAccounts = response["accounts"]?.array,
          !rawRequests.isEmpty, !rawAccounts.isEmpty,
          response["commandOwnerConfigured"]?.bool != nil,
          response["limits"]?["pendingPerAccount"]?.int != nil, response["limits"]?["ttlMs"]?.double != nil else {
        check(false, "actual pairing response has full nonempty requests/accounts/owner/limits")
        task.cancel(); gate.release(); await task.value; return
    }
    let requests = PairingInboxModel.sorted(rawRequests.compactMap(PairingRequest.init)), accounts = rawAccounts.compactMap(PairingAccount.init)
    guard requests.count == rawRequests.count && accounts.count == rawAccounts.count else {
        check(false, "every actual pairing record decodes fully"); task.cancel(); gate.release(); await task.value; return
    }
    check(true, "full nonempty actual pairing response is ready before cancellation")
    let canceled = Task { await model.load() }; canceled.cancel(); await canceled.value
    gate.release(); await task.value
    check(attempts == 1, "pre-canceled pairing load admits no second request")
    check(model.requests == requests && model.accounts == accounts, "full actual pairing requests/accounts survive canceled load")
    let expectedTTL = response["limits"]?["ttlMs"]?.double.map { $0 / 1000 }
    check(model.commandOwnerConfigured == response["commandOwnerConfigured"]?.bool
          && model.limits?.pendingPerAccount == response["limits"]?["pendingPerAccount"]?.int
          && model.limits?.ttl == expectedTTL, "actual pairing owner and limits survive canceled load")
    check(model.loadState == .idle && model.hasLoaded && model.supported && model.canManage, "healthy pairing read completes after canceled caller")
}
@MainActor func runPairingInboxCanceledAdmissionChecks() async {
    await checkPairingCanceledAdmission { _, _ in
        ["accounts": [["channel": "telegram", "channelLabel": "Telegram", "accountId": "home", "accountLabel": "Home bot", "notifySupported": true]],
         "requests": [["requestId": "fixture-request", "channel": "telegram", "channelLabel": "Telegram", "accountId": "home", "senderId": "4411", "senderLabel": "Telegram user id", "createdAt": "2026-10-04T19:00:00Z", "lastSeenAt": "2026-10-04T19:00:00Z", "expiresAt": "2026-10-04T20:00:00Z", "notifySupported": true]],
         "commandOwnerConfigured": false, "limits": ["pendingPerAccount": 3, "ttlMs": 3600000]]
    }
}
@MainActor func runDemoPairingInboxCanceledAdmissionChecks() async {
    let (defaults,suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    guard await waitFor("pairing inbox Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else { check(false, "actual Demo connects"); return }
    await checkPairingCanceledAdmission { method, params in try await gateway.connection.request(method, params, timeout: 30) }
}
