#if DEBUG
import Foundation
@testable import PincerKit

@MainActor
private final class QRResponseDelivery {
    var entered = false
    private var cancellationObserved = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        self.entered = true
        // This response is already computed; observing cancellation cannot revoke it.
        // The owning check releases the local delivery gate in its cleanup.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: { Task { @MainActor in self.cancellationObserved = true } }
    }
    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
func runChannelQRLoginOwnershipChecks() async {
    for replacement in ["cancel", "restart", "reset"] {
        let old = QRResponseDelivery()
        let fresh = QRResponseDelivery()
        var starts = 0
        var returned = false
        var linked = 0
        let controller = ChannelQRLoginController(request: { method, params in
            check(params["channel"] == "whatsapp" && params["accountId"] == "default", "QR requests retain the selected account")
            if method == "web.login.start" {
                starts += 1
                return ["qrDataUrl": .string(starts == 1 ? "data:image/png;base64,AQ==" : "data:image/png;base64,Ag==")]
            }
            check(method == "web.login.wait", "QR wait uses the existing Gateway method")
            if starts == 1 {
                let result: JSONValue = ["connected": false, "message": "The login QR expired. Ask me to generate a new one."]
                await old.hold()
                returned = true
                return result
            }
            await fresh.hold()
            return ["connected": false, "message": "Still waiting for the QR scan. Let me know when you’ve scanned it."]
        })
        controller.onLinked = { _ in linked += 1 }
        defer { controller.reset(); old.release(); fresh.release() }
        controller.start(channel: "whatsapp", accountId: "default")
        let admitted = await waitFor("old QR response computed", timeout: 120) { old.entered }
        check(admitted, "the real controller reaches the held completed wait")
        guard admitted else { return }
        guard let oldTask = controller.activeTaskForChecks(channel: "whatsapp", accountId: "default") else {
            check(false, "the held response has its actual controller task"); return
        }
        if replacement == "cancel" { controller.cancel(channel: "whatsapp", accountId: "default") }
        else if replacement == "reset" { controller.reset() }
        else {
            controller.start(channel: "whatsapp", accountId: "default", force: true)
            let replacementReady = await waitFor("replacement QR response", timeout: 120) { fresh.entered }
            check(replacementReady, "replacement reaches its actual new QR wait")
            guard replacementReady else { return }
        }
        old.release()
        await oldTask.value
        check(returned, "the real controller task consumed the completed canceled response")
        let expected: ChannelQRLoginState = replacement == "restart" ? .showing(qr: Data([2]), message: nil) : .idle
        check(controller.state(channel: "whatsapp", accountId: "default") == expected && linked == 0,
              "late terminal response cannot restore canceled state or replace a fresh QR")
    }
    var linked = 0
    let current = ChannelQRLoginController(request: { _, _ in ["connected": true, "message": "Linked"] })
    current.onLinked = { _ in linked += 1 }
    defer { current.reset() }
    current.start(channel: "whatsapp", accountId: "default")
    guard let currentTask = current.activeTaskForChecks(channel: "whatsapp", accountId: "default") else {
        check(false, "current login exposes its actual task before execution"); return
    }
    await currentTask.value
    check(linked == 1 && current.state(channel: "whatsapp", accountId: "default") == .connected("Linked"),
          "current successful login still publishes and calls the linkage handler")
}

@MainActor
func runDemoChannelQRLoginOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("QR ownership Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "QR ownership connects to the genuine Demo Gateway")
    guard connected else { return }
    let delivery = QRResponseDelivery()
    var returned = false
    var linked = 0
    let controller = ChannelQRLoginController(request: { method, params in
        let response = try await gateway.connection.request(method, params)
        if method == "web.login.start" {
            // Advance the isolated Demo's actual backend through its QR rotation and
            // linkage before delivering the original start response. This simulates
            // server-side completion, not a physical scan or an expiration policy.
            var wait: JSONValue = ["channel": "whatsapp", "accountId": "default", "timeoutMs": 120000,
                                   "currentQrDataUrl": response["qrDataUrl"] ?? .null]
            let rotated = try await gateway.connection.request("web.login.wait", wait)
            wait = ["channel": "whatsapp", "accountId": "default", "timeoutMs": 120000,
                    "currentQrDataUrl": rotated["qrDataUrl"] ?? .null]
            let completed = try await gateway.connection.request("web.login.wait", wait)
            check(completed["connected"] == true, "real Demo wait completes backend linkage")
        } else {
            check(response["connected"] == false && response["qrDataUrl"] == nil
                  && response["message"] == "No active WhatsApp login in progress.",
                  "actual Demo returns its no-active-login terminal result, not fabricated expiration")
            await delivery.hold()
            returned = true
        }
        return response
    })
    controller.onLinked = { _ in linked += 1 }
    defer { controller.reset(); delivery.release() }
    controller.start(channel: "whatsapp", accountId: "default", force: true)
    let admitted = await waitFor("actual Demo terminal QR response", timeout: 120) { delivery.entered }
    check(admitted, "hold the genuine completed terminal result before publication")
    guard admitted else { return }
    guard let oldTask = controller.activeTaskForChecks(channel: "whatsapp", accountId: "default") else {
        check(false, "actual Demo terminal response retains its active controller task"); return
    }
    controller.cancel(channel: "whatsapp", accountId: "default")
    delivery.release()
    await oldTask.value
    check(returned && controller.state(channel: "whatsapp", accountId: "default") == .idle && linked == 0,
          "Cancel remains idle after genuine terminal delivery and suppresses the old callback")
    do {
        let backend = try await gateway.connection.request("web.login.start", ["channel": "whatsapp", "accountId": "default", "force": false])
        check(WebLoginResult(backend).message.map(ChannelQRLoginController.isAlreadyLinked) == true,
              "ignoring stale local feedback does not undo the real backend linkage")
    } catch { check(false, "read actual Demo linkage after cancellation") }
    let current = ChannelQRLoginController(request: { try await gateway.connection.request($0, $1) })
    var currentLinked = 0
    current.onLinked = { _ in currentLinked += 1 }
    defer { current.reset() }
    current.start(channel: "whatsapp", accountId: "default", force: true)
    guard let currentTask = current.activeTaskForChecks(channel: "whatsapp", accountId: "default") else {
        check(false, "normal Demo login exposes its actual task before execution"); return
    }
    await currentTask.value
    check(currentLinked == 1 && current.state(channel: "whatsapp", accountId: "default").isRunning == false,
          "normal genuine Demo QR rotation and linkage still complete exactly once")
}

#endif
