import Foundation
@testable import PincerKit

/// #547: a caller waiting on the shared in-flight `load()` that is itself cancelled returns at once,
/// and the shared load still finishes for everyone else. The demo's `chat.history` is held open.
@MainActor
func runDemoSharedLoadChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("demo for shared load") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for shared load connected")
    guard connected else { return }
    let key = "agent:main:dashboard:garden"
    await gateway.connection.holdDemoHistory(true)
    let baseline = await gateway.connection.demoHistoryRequestCount(for: key)
    let chat = gateway.chat(for: key)
    chat.markStale()
    let starter = Task { await chat.load() }
    var requested = false
    for _ in 0..<1000 {
        if await gateway.connection.demoHistoryRequestCount(for: key) > baseline { requested = true; break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    check(requested, "the starter's chat.history is held in flight")
    let returned = Flag()
    let waiter = Task { await chat.load(); returned.set() }
    for _ in 0..<20 { await Task.yield() }
    waiter.cancel()
    let prompt = await waitFor("cancelled waiter returns", timeout: 2) { returned.value }
    check(prompt && chat.loadInFlight, "a cancelled waiter returns while the shared load keeps running")
    await gateway.connection.holdDemoHistory(false)
    await starter.value
    check(chat.hasLoaded && !chat.items.isEmpty && !chat.loadInFlight, "the shared load still finishes")
    check(chat.loadCount == 1, "one load for both callers (\(chat.loadCount))")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { self.lock.withLock { self.flag } }
    func set() { self.lock.withLock { self.flag = true } }
}
