#if DEBUG
import Foundation
@testable import PincerKit

private actor QuickCaptureDeliveryGate {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold(_ method: String) async {
        guard method == "chat.send" else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { await self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor private func checkQuickCapturePendingTarget(selectionChanges: Int) async {
    let (defaults, suite) = scratchDefaults()
    GatewayProfileStore.save([.demo()], to: defaults)
    let app = AppModel(defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    guard let gateway = app.gateways.first else { check(false, "owned Demo profile loads"); defaults.removePersistentDomain(forName: suite); return }
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("Quick Capture owned Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo bootstrap completed"); guard ready else { return }
    let model = QuickCaptureModel(app: app, defaults: defaults)
    let items = model.items
    guard let first = items.first(where: { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:main" }; return false }),
          let next = items.first(where: { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:dashboard:trip" }; return false }),
          first.isEnabled, next.isEnabled else { check(false, "two actual enabled seeded chat targets exist"); return }
    check(model.pick(first), "actual pick selects the send target")
    let nonce = "quick-target-" + UUID().uuidString
    model.text = nonce
    await gateway.connection.demoTrackSendRequests(matchingText: nonce)
    let gate = QuickCaptureDeliveryGate()
    await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
    let sending = Task { await model.send() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await gate.entered), !Task.isCancelled, ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    let entered = await gate.entered
    check(entered, "real chat.send response was computed before delivery is held")
    guard entered else {
        sending.cancel(); await gate.release(); _ = await sending.value
        await gateway.connection.setDemoResponseDelivery(nil)
        await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
        return
    }
    let requests = await gateway.connection.demoSendRequests(matchingText: nonce)
    check(requests.count == 1 && requests.first?.idempotencyKey.isEmpty == false && model.isSending,
          "one actual nonce-tagged chat.send is held while the model is sending")
    if selectionChanges > 0 { check(model.pick(next), "actual pick selects the newer target during the send") }
    if selectionChanges == 2 { check(model.pick(first), "actual pick returns to the original target with newer intent") }
    let expected = selectionChanges == 0 ? nil : QuickCaptureTarget(item: selectionChanges == 2 ? first : next)
    await gate.release()
    let accepted = await sending.value
    check(accepted && !model.isSending && model.error == nil && model.text.isEmpty, "actual accepted send completes and clears its sent text")
    check(model.settings.lastTarget == QuickCaptureTarget(item: first), "remembered sent target remains the actual first chat")
    check(model.target == expected, "completed prior send preserves only a newer picked target")
    await gateway.connection.setDemoResponseDelivery(nil)
    await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
}

@MainActor func runQuickCaptureSendTargetOwnershipChecks() async {
    await checkQuickCapturePendingTarget(selectionChanges: 0)
    await checkQuickCapturePendingTarget(selectionChanges: 1)
    await checkQuickCapturePendingTarget(selectionChanges: 2)
}
@MainActor func runDemoQuickCaptureSendTargetOwnershipChecks() async {
    await checkQuickCapturePendingTarget(selectionChanges: 1)
    await checkQuickCapturePendingTarget(selectionChanges: 2)
}
#endif
