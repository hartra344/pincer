#if DEBUG
import Foundation
@testable import PincerKit

/// Parks the demo's computed `sessions.list` results until released.
private actor RefreshListGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold(_ method: String) async {
        guard method == "sessions.list" else { return }
        self.entered = true
        guard !self.released else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func release() {
        self.released = true
        let parked = self.waiters
        self.waiters = []
        for waiter in parked { waiter.resume() }
    }
}

/// #1022: a row change that lands while a `sessions.list` refresh is in flight wins over that
/// refresh's (older) snapshot, so a chat moved into a group doesn't snap back out.
@MainActor
func runDemoSessionListRefreshReconcileChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start()
    gateway.reconnectIfNeeded()
    let key = "agent:mochi:dashboard:utilities"
    let ready = await waitFor("demo for refresh reconcile", timeout: 60) { gateway.bootstrapped && gateway.sessions[key] != nil }
    check(ready, "demo for refresh reconcile bootstrapped")
    guard ready, gateway.sessions[key]?.category == nil else { check(!ready, "the utilities chat starts ungrouped"); return }

    let gate = RefreshListGate()
    await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
    let refresh = Task { await gateway.refreshSessions() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while !(await gate.entered), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    let held = await gate.entered
    await gateway.connection.setDemoResponseDelivery(nil)
    check(held, "the refresh's sessions.list is computed and held")
    guard held else { await gate.release(); await refresh.value; return }

    await gateway.patch(key, ["category": .string("Day of move")])
    let applied = await waitFor("row change during refresh", timeout: 60) { gateway.sessions[key]?.category == "Day of move" }
    check(applied, "the row change applies while the refresh is in flight")
    await gate.release()
    await refresh.value
    check(gateway.sessions[key]?.category == "Day of move", "the refresh's older snapshot doesn't undo the newer row change")
}
#endif
