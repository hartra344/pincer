import Foundation
@testable import PincerKit

/// Starts a raw `GatewayConnection`; `ready.value` flips once it is connected. Callers own the wait
/// (`waitFor`) and `stop()`, so each check keeps its own timeout and failure message.
@MainActor
func startRawConnection(_ profile: GatewayProfile) async -> (connection: GatewayConnection, ready: Scripted<Bool>) {
    let connection = GatewayConnection(profile: profile)
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    return (connection, ready)
}

@MainActor func checkRawConnectionSupport() async {
    let (connection, ready) = await startRawConnection(.demo())
    defer { Task { await connection.stop() } }
    let connected = await waitFor("raw connection helper demo", timeout: 25) { ready.value }
    check(connected, "startRawConnection: the demo raw connection reports ready")
    guard connected else { return }
    let hello = try? await connection.request("health", [:])
    check(hello != nil, "startRawConnection: the connection serves requests once ready")
}
