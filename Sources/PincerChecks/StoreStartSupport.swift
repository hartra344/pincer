import Foundation
@testable import PincerKit

/// Starts a `GatewayStore` for `profile` and waits until it is connected and has sessions. Callers own the
/// `connected` check message and `stop()`, so each site keeps its own wording and defer placement.
@MainActor
func startStore(_ profile: GatewayProfile, waiting label: String, timeout: Double = 15,
                reconnect: Bool = false) async -> (gateway: GatewayStore, connected: Bool) {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    if reconnect { gateway.reconnectIfNeeded() }
    let connected = await waitFor(label, timeout: timeout) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    return (gateway, connected)
}
