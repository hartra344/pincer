#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class PaletteCheckGate {
    var entered = false, open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { if open { $0.resume() } else { held = $0 } } }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor private func checkPaletteOwnership(_ items: [PaletteItem], query: String, expected: [String]) async {
    let coordinator = PaletteSearchCoordinator(), gate = PaletteCheckGate(), owner = UUID()
    coordinator.appear(); coordinator.didPrepare = { await gate.hold() }
    let revision = coordinator.source.current
    let request = Task { await coordinator.prepare(items, bookmarks: [], query: query, page: .models,
        gatewaySelected: false, shortcut: nil, owner: owner, revision: revision) }
    let entered = await waitFor("completed palette worker", timeout: 15) { gate.entered }
    check(entered, "real ranking worker completed before source invalidation")
    guard entered, let actual = coordinator.actualWorkerTask else {
        request.cancel(); coordinator.disappear(); gate.release(); await request.value; return
    }
    check(coordinator.source.changed(revision), "source invalidation marks current ownership synchronously")
    check(coordinator.activeCount == 1, "completed held worker retains the only active lease")
    gate.release(); await actual.value
    let accepted = await request.value
    check(!accepted && coordinator.result == nil && !coordinator.owns(owner) && coordinator.activeCount == 0,
          "actual terminal stale worker cannot publish or remain actionable")
    coordinator.didPrepare = nil
    let latestOwner = UUID()
    let current = await coordinator.prepare(items, bookmarks: [], query: query, page: .models,
        gatewaySelected: false, shortcut: nil, owner: latestOwner, revision: coordinator.source.current)
    check(current && coordinator.owns(latestOwner) && coordinator.result?.items.map(\.id) == expected,
          "new current worker publishes exact source IDs after old worker exits")
    check(!coordinator.owns(latestOwner, environment: PaletteEnvironmentKey(thinking: "changed")),
          "changed live environment rejects old action before queued refresh")
    let messageOwner = UUID(), messageGateway = UUID()
    let retainedOwner = PaletteSearchPreparation.ownerAfterEnvironmentChange(messageOwner, page: .messages)
    check(retainedOwner == messageOwner && PaletteSearchPreparation.messagesAreCurrent(owner: messageOwner,
          currentOwner: retainedOwner, gateway: messageGateway, currentGateway: messageGateway),
          "rank-only environment changes retain actionable current message results")
    check(!PaletteSearchPreparation.messagesAreCurrent(owner: messageOwner, currentOwner: UUID(),
          gateway: messageGateway, currentGateway: messageGateway)
          && !PaletteSearchPreparation.messagesAreCurrent(owner: messageOwner, currentOwner: messageOwner,
          gateway: messageGateway, currentGateway: UUID()), "query and gateway ownership still retire message results")
    coordinator.disappear()
    check(coordinator.result == nil && !coordinator.owns(latestOwner), "presentation teardown clears finished display and action ownership")
}
@MainActor func runPaletteSearchOwnershipChecks() async {
    let items = [PaletteItem(id: "one", title: "First", symbol: "x", section: .chats, action: .command("one"))]
    await checkPaletteOwnership(items, query: "First", expected: ["one"])
}
@MainActor func runDemoPaletteSearchOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults(), key = "agent:main:dashboard:rate-limiter"
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("owned palette Demo inventory", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil }
    check(ready, "real Demo inventory completed"); guard ready else { return }
    let items = CommandPalette.chatItems(gateways: [gateway], selectedGatewayId: gateway.id, recent: [])
    let expected = "chat:\(gateway.id.uuidString):\(key)"
    guard items.contains(where: { $0.id == expected && $0.title == "Rate limiter design" }) else {
        check(false, "actual Demo source contains exact expected chat"); return
    }
    await checkPaletteOwnership(items, query: "rate limiter design", expected: [expected])
}
#endif
