#if DEBUG
import Foundation
@testable import PincerKit

private actor PaletteCreationDelivery {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold(_ method: String) async {
        guard method == "sessions.create" else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { await self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor private func checkPaletteCreation(change: Int, palette: Bool) async {
    let (defaults, suite) = scratchDefaults()
    GatewayProfileStore.save([.demo(), .demo()], to: defaults)
    let app = AppModel(defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    guard let gateway = app.gateways.first, let other = app.gateways.last, gateway.id != other.id else {
        check(false, "two actual Demo profiles are available"); defaults.removePersistentDomain(forName: suite); return
    }
    for store in app.gateways { store.cacheRoot = nil; store.outboxRoot = nil; store.notifier = nil; store.start(); store.reconnectIfNeeded() }
    defer { app.gateways.forEach { $0.stop() }; defaults.removePersistentDomain(forName: suite) }
    let ready = await waitFor("actual palette creation Demo bootstrap", timeout: 25) { app.gateways.allSatisfy { $0.state.isConnected && $0.bootstrapped } }
    guard ready, gateway.hello?.methods.contains("sessions.create") == true,
          let first = gateway.sortedRows.first?.key,
          let second = gateway.sortedRows.first(where: { $0.key != first })?.key,
          let otherKey = other.sortedRows.first?.key else {
        check(false, "actual advertised creation and distinct seeded chats are ready"); return
    }
    check(true, "actual Demo creation method and nonempty distinct chat inventory")
    app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: first))
    if change == 4 { app.open(Notifier.Target(gatewayId: other.id, sessionKey: otherKey)) }
    let before = Set(gateway.sessions.keys)
    let delivery = PaletteCreationDelivery()
    await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
    let action = Task {
        if palette { return await app.createPaletteChat(gateway: gateway, agentId: "research") }
        return await gateway.createSession(agentId: "research", label: nil)
    }
    let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    var admitted = await delivery.entered
    while !admitted && !Task.isCancelled && ContinuousClock.now < admissionDeadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        admitted = await delivery.entered
    }
    guard admitted else {
        check(false, "actual create response is held")
        action.cancel(); await delivery.release(); _ = await action.value
        await gateway.connection.setDemoResponseDelivery(nil); return
    }
    check(gateway.selectedKey == first && app.selectedGatewayId == (change == 4 ? other.id : gateway.id), "creation admission preserves current chat")
    if change == 1 || change == 3 {
        app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: second))
        if change == 3 { app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: first)) }
    } else if change == 2 { app.open(Notifier.Target(gatewayId: other.id, sessionKey: otherKey)) }
    let expectedKey = gateway.selectedKey, expectedGateway = app.selectedGatewayId
    let opensBeforeCompletion = app.openRequests
    await delivery.release()
    let created = await action.value
    await gateway.connection.setDemoResponseDelivery(nil)
    guard let created else { check(false, "actual creation completes successfully"); return }
    check(created.hasPrefix("agent:research:") && gateway.sessions[created]?.key == created && Set(gateway.sessions.keys).subtracting(before) == [created], "actual creation adds exactly its real row")
    if change == 0 || change == 4 {
        check(gateway.selectedKey == created && app.selectedGatewayId == gateway.id && app.openRequests == opensBeforeCompletion + (palette ? 1 : 0), "unchanged actual creation selects and opens normally")
    } else {
        check(gateway.selectedKey == expectedKey && app.selectedGatewayId == expectedGateway, "actual creation retains newer chat/Gateway/ABA selection")
        check(app.openRequests == opensBeforeCompletion, "actual palette completion cannot reopen over newer choice")
    }
}
@MainActor func runPaletteCreateSelectionOwnershipChecks() async {
    for change in [0, 1, 2, 3, 4] { await checkPaletteCreation(change: change, palette: true) }
    for change in [0, 1, 3] { await checkPaletteCreation(change: change, palette: false) }
}
@MainActor func runDemoPaletteCreateSelectionOwnershipChecks() async {
    for change in [0, 1, 2, 3, 4] { await checkPaletteCreation(change: change, palette: true) }
}
#endif
