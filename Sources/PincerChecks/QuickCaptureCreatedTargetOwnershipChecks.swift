#if DEBUG
import Foundation
@testable import PincerKit

private actor QuickCaptureCreationDeliveryGate {
    var createEntered = false, sendEntered = false
    var createReleased = false, sendReleased = false
    var createWaiter: CheckedContinuation<Void, Never>?, sendWaiter: CheckedContinuation<Void, Never>?
    func hold(_ method: String) async {
        guard method == "sessions.create" || method == "chat.send" else { return }
        let creation = method == "sessions.create"
        if creation { createEntered = true } else { sendEntered = true }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if creation {
                    if createReleased { continuation.resume() } else { createWaiter = continuation }
                } else {
                    if sendReleased { continuation.resume() } else { sendWaiter = continuation }
                }
            }
        } onCancel: { Task { await self.releaseAll() } }
    }
    func releaseCreate() { createReleased = true; createWaiter?.resume(); createWaiter = nil }
    func releaseAll() { releaseCreate(); sendReleased = true; sendWaiter?.resume(); sendWaiter = nil }
}

@MainActor private func checkQuickCaptureCreatedTarget(changeTarget: Bool) async {
    let (defaults, suite) = scratchDefaults()
    GatewayProfileStore.save([.demo()], to: defaults)
    let app = AppModel(defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    guard let gateway = app.gateways.first else { check(false, "owned Demo profile loads"); defaults.removePersistentDomain(forName: suite); return }
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("Quick Capture creation Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo bootstrap completed"); guard ready else { return }
    let model = QuickCaptureModel(app: app, defaults: defaults)
    let items = model.items
    guard let creation = items.first(where: { if case let .newChat(_, agentId) = $0.action { return agentId == "research" }; return false }),
          let next = items.first(where: { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:dashboard:trip" }; return false }),
          creation.isEnabled, next.isEnabled else { check(false, "actual enabled research creation and next chat targets exist"); return }
    check(model.pick(creation), "actual pick selects New Chat")
    let before = Set(gateway.sessions.keys)
    let nonce = "quick-create-target-" + UUID().uuidString
    model.text = nonce
    await gateway.connection.demoTrackSendRequests(matchingText: nonce)
    let gate = QuickCaptureCreationDeliveryGate()
    await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
    let sending = Task { await model.send() }
    func cleanup() async {
        sending.cancel(); await gate.releaseAll(); _ = await sending.value
        await gateway.connection.setDemoResponseDelivery(nil)
        await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
    }
    let createDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await gate.createEntered), !Task.isCancelled, ContinuousClock.now < createDeadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    let createEntered = await gate.createEntered
    check(createEntered, "actual sessions.create result is computed and held")
    guard createEntered, !Task.isCancelled else { await cleanup(); return }
    let preSend = await gateway.connection.demoSendRequests(matchingText: nonce)
    check(preSend.isEmpty && model.isSending, "no chat.send precedes delivery of actual creation result")
    if changeTarget { check(model.pick(next), "actual pick selects B while creation is held") }
    await gate.releaseCreate()
    let sendDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    while (!(await gate.sendEntered) || Set(gateway.sessions.keys).subtracting(before).isEmpty), !Task.isCancelled, ContinuousClock.now < sendDeadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    let sendEntered = await gate.sendEntered
    let createdKeys = Set(gateway.sessions.keys).subtracting(before)
    check(sendEntered && createdKeys.count == 1, "actual created session and computed send result are available")
    guard sendEntered, createdKeys.count == 1, let created = createdKeys.first, !Task.isCancelled else { await cleanup(); return }
    let createdTarget = QuickCaptureTarget(gatewayId: gateway.id, target: .chat(created))
    let requests = await gateway.connection.demoSendRequests(matchingText: nonce)
    check(created.hasPrefix("agent:research:") && requests.count == 1 && requests.first?.idempotencyKey.isEmpty == false,
          "actual research chat is created and one nonce-tagged send is held")
    check(model.target == (changeTarget ? QuickCaptureTarget(item: next) : createdTarget), "creation completion preserves newer B while send remains held")
    await gate.releaseAll()
    let accepted = await sending.value
    check(accepted && !model.isSending && model.error == nil && model.text.isEmpty, "actual created-chat send completes")
    check(model.settings.lastTarget == createdTarget, "remembered sent target is the actual created chat")
    check(model.target == (changeTarget ? QuickCaptureTarget(item: next) : nil), "created-chat send completion preserves newer B")
    await gateway.connection.setDemoResponseDelivery(nil)
    await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
}

@MainActor func runQuickCaptureCreatedTargetOwnershipChecks() async {
    await checkQuickCaptureCreatedTarget(changeTarget: false)
    await checkQuickCaptureCreatedTarget(changeTarget: true)
}
@MainActor func runDemoQuickCaptureCreatedTargetOwnershipChecks() async {
    await checkQuickCaptureCreatedTarget(changeTarget: true)
}
#endif
