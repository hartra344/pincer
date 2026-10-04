import Foundation
import PincerKit

@MainActor private final class PairingCanceledReplyGate {
    var entered = false, open = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        // Intentionally delivers a computed reply after cancellation.
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { self.continuation = continuation }
        }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

@MainActor func runPairingInboxLoadCancellationChecks() async {
    let source: JSONValue = [
        "accounts": [["channel": "telegram", "channelLabel": "Telegram", "accountId": "home", "notifySupported": true]],
        "requests": [["requestId": "known", "channel": "telegram", "channelLabel": "Telegram", "accountId": "home",
                      "senderId": "4411", "senderLabel": "Telegram user id", "createdAt": "2026-10-04T19:00:00Z",
                      "lastSeenAt": "2026-10-04T19:00:00Z", "expiresAt": "2026-10-04T20:00:00Z", "notifySupported": true]],
        "commandOwnerConfigured": false, "limits": ["pendingPerAccount": 3, "ttlMs": 3600000],
    ]
    for outcome in ["success", "UNKNOWN_METHOD", "missing-scope", "UNAVAILABLE"] {
        let gate = PairingCanceledReplyGate()
        var attempts = 0
        let model = PairingInboxModel { method, params in
            check(method == PairingInboxModel.listMethod && params == [:], "canceled pairing reply retains exact read request")
            attempts += 1
            if attempts == 1 { return source }
            await gate.hold()
            if outcome == "success" { return ["accounts": [], "requests": [], "commandOwnerConfigured": true, "limits": ["pendingPerAccount": 0, "ttlMs": 0]] }
            throw GatewayError.rpc(code: outcome == "missing-scope" ? "INVALID_REQUEST" : outcome,
                                   message: outcome == "missing-scope" ? "missing scope: operator.pairing" : "Obsolete pairing error", details: nil)
        }
        await model.load()
        let requests = model.requests, accounts = model.accounts, limits = model.limits
        check(requests.count == 1 && accounts.count == 1, "known complete pairing state precedes canceled admitted reply")
        let task = Task { await model.load() }
        guard await waitFor("admitted pairing reply", timeout: 15, { gate.entered }) else {
            check(false, "admitted pairing response reaches its gate")
            task.cancel(); gate.release(); await task.value; return
        }
        task.cancel(); gate.release(); await task.value
        check(attempts == 2 && model.requests == requests && model.accounts == accounts && model.limits == limits,
              "canceled admitted \(outcome) preserves the full known pairing state")
        check(model.loadState == .idle && model.hasLoaded && model.supported && !model.needsAccess && !model.commandOwnerConfigured,
              "canceled admitted \(outcome) changes no capability or terminal policy")
    }
}
