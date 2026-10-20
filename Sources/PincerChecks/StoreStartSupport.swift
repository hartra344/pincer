import Foundation
@testable import PincerKit

/// Starts a `GatewayStore` for `profile` and waits until `ready` holds (default: connected and has sessions).
/// `prepare` runs before `start()`. Callers own the `connected` check message and `stop()`, so each site keeps
/// its own wording and defer placement.
@MainActor
func startStore(_ profile: GatewayProfile, waiting label: String, timeout: Double = 15, reconnect: Bool = false,
                defaults: UserDefaults? = nil, prepare: (GatewayStore) -> Void = { _ in },
                until ready: (GatewayStore) -> Bool = { $0.state.isConnected && !$0.sessions.isEmpty })
    async -> (gateway: GatewayStore, connected: Bool) {
    let gateway = defaults.map { GatewayStore(profile: profile, defaults: $0) } ?? GatewayStore(profile: profile)
    prepare(gateway)
    gateway.start()
    if reconnect { gateway.reconnectIfNeeded() }
    let connected = await waitFor(label, timeout: timeout) { ready(gateway) }
    return (gateway, connected)
}

@MainActor func checkStartStoreSupport() async {
    // A fresh profile id keeps the process-wide message index of the shared demo id untouched for later suites.
    var profile = GatewayProfile.demo()
    profile.id = UUID()
    let (gateway, connected) = await startStore(profile, waiting: "startStore helper demo", timeout: 25, reconnect: true,
                                                prepare: { $0.cacheRoot = nil; $0.outboxRoot = nil; $0.notifier = nil })
    defer { gateway.stop() }
    check(connected, "startStore: the demo store is connected with sessions once the wait returns")
    let (custom, hello) = await startStore(profile, waiting: "startStore helper until", timeout: 25, prepare: { $0.cacheRoot = nil },
                                           until: { $0.state.isConnected && $0.hello != nil })
    defer { custom.stop() }
    check(hello && custom.cacheRoot == nil, "startStore: prepare runs before start and a custom ready closure replaces the default")
}
