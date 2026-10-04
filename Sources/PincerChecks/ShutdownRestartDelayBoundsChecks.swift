import Foundation
@testable import PincerKit

@MainActor func runShutdownRestartDelayBoundsChecks() {
    check(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": 1500]) == 1500,
          "ordinary shutdown restart delay remains unchanged")
    check(GatewayHealthModel.restartExpectedMs(shutdown: ["reason": "stop"]) == nil,
          "missing delay remains a terminal stop")
    let model = GatewayHealthModel { _, _ in .null }
    model.handle(event: "shutdown", payload: ["reason": "restart", "restartExpectedMs": .number(1e30)])
    check(model.restartState == .restarting && model.indicator == .restarting,
          "official unbounded integer delay reaches actual restart state without trapping")
    model.connectionChanged(.connected, hello: nil)
    check(model.restartState == .restarted(uptimeMs: nil), "connected cleanup finishes restart state")
    let terminal = GatewayHealthModel { _, _ in .null }
    terminal.handle(event: "shutdown", payload: ["reason": "stop"])
    check(terminal.restartState == .idle, "terminal shutdown does not start a restart timer")
}

@MainActor func runDemoShutdownRestartDelayBoundsChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("shutdown bounds Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "connect to the genuine Demo before local shutdown-event coverage")
    guard connected else { return }
    let model = GatewayHealthModel { method, params in
        try await gateway.connection.request(method, params)
    }
    await model.load()
    check(model.health != nil, "actual Demo health response loads before the local event overlay")
    // Explicit official-schema event overlay: the Demo backend is not restarted.
    model.handle(event: "shutdown", payload: ["reason": "restart", "restartExpectedMs": .number(1e30)])
    check(model.restartState == .restarting && model.indicator == .restarting,
          "local official shutdown overlay starts actual restart state without trapping")
    model.connectionChanged(.connected, hello: nil)
    if case .restarted = model.restartState { check(true, "actual connected event cleans restart timers") }
    else { check(false, "actual connected event cleans restart timers") }
}
