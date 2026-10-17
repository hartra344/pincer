import Foundation
import Testing
@testable import PincerKit

#if DEBUG
/// Parks the demo's computed `sessions.list` result until released, so a row event can land first.
private actor ListDeliveryGate {
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

/// #1022: a `sessions.list` read before a row change used to overwrite that change when its result
/// was applied after the row's `sessions.changed`, so a chat moved into a group snapped back out.
@MainActor
@Suite("Session list refresh reconcile")
struct SessionListRefreshReconcileTests {
    static let key = "agent:mochi:dashboard:utilities"

    @Test func aRowChangeDuringARefreshWinsOverItsSnapshot() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.start()
        defer { gateway.stop() }
        let ready = await eventually(timeout: .seconds(60)) {
            gateway.bootstrapped && gateway.sessions[Self.key] != nil
        }
        try #require(ready, "demo not ready: state=\(gateway.state) sessions=\(gateway.sessions.count)")
        try #require(gateway.sessions[Self.key]?.category == nil)

        let gate = ListDeliveryGate()
        await gateway.connection.setDemoResponseDelivery { await gate.hold($0) }
        let refresh = Task { await gateway.refreshSessions() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let held = await gate.entered
        await gateway.connection.setDemoResponseDelivery(nil)
        guard held else {
            await gate.release(); await refresh.value
            Issue.record("the refresh's sessions.list was never computed")
            return
        }

        await gateway.patch(Self.key, ["category": .string("Day of move")])
        let applied = await eventually(timeout: .seconds(60)) { gateway.sessions[Self.key]?.category == "Day of move" }
        #expect(applied, "the row event applies while the refresh is in flight")

        await gate.release()
        await refresh.value
        #expect(gateway.sessions[Self.key]?.category == "Day of move",
                "the older snapshot must not undo the newer row change")
    }
}
#endif
