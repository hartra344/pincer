import Foundation
@testable import PincerKit

@MainActor func runSessionSpokenDurationChecks() {
    guard let row = SessionRow(["key": "local-duration", "runtimeMs": .number(1e30)]),
          let elapsed = SessionManager.runDuration(row, now: Date(timeIntervalSince1970: 0)) else {
        check(false, "local legal finite runtime reaches the actual duration path"); return
    }
    check(!SessionManager.spokenDuration(elapsed).isEmpty, "actual row spoken formatter safely handles the local large finite runtime")
}

@MainActor func runDemoSessionSpokenDurationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("spoken duration Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo session source is connected")
    guard ready else { return }
    await gateway.sessionManager.load(filter: .all)
    guard let row = gateway.sessionManager.rows.first(where: { SessionManager.runDuration($0, now: Date()) != nil }),
          let elapsed = SessionManager.runDuration(row, now: Date()) else {
        check(false, "actual Demo sessions list supplies a run duration"); return
    }
    check(!SessionManager.spokenDuration(elapsed).isEmpty, "genuine Demo row uses the unchanged actual spoken formatter")
    // Explicitly LOCAL numeric boundary, not an altered Gateway response.
    runSessionSpokenDurationChecks()
}
