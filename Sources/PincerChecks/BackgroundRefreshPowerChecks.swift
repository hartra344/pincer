@testable import PincerKit

@MainActor func runBackgroundRefreshPowerChecks() {
    var lowPower = false
    let state = BackgroundRefreshPowerState(read: { lowPower })
    check(!state.showsPauseNote(delivery: .backgroundRefresh), "normal power has no pause note")
    lowPower = true; state.refresh()
    check(state.showsPauseNote(delivery: .backgroundRefresh), "current low power explains background refresh pause")
    check(!state.showsPauseNote(delivery: .pushRelay) && !state.showsPauseNote(delivery: .off), "other delivery modes have no background pause note")
    lowPower = false; state.refresh()
    check(!state.showsPauseNote(delivery: .backgroundRefresh), "current power transition removes pause note")
}

@MainActor func runDemoBackgroundRefreshPowerChecks() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        defaults.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(.demo(), secret: nil)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    let ready = await waitFor("background power Demo settings", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped && !gateway.sessions.isEmpty
    }
    check(ready, "actual Demo app has a connected nonempty gateway"); guard ready else { return }
    ClosedAppDelivery.set(.backgroundRefresh, defaults)
    let deliveryPreference = defaults.string(forKey: ClosedAppDelivery.key)
    let notificationsEnabled = app.notifier.enabled
    var lowPower = false
    let state = BackgroundRefreshPowerState(read: { lowPower })
    check(!state.showsPauseNote(delivery: ClosedAppDelivery.current(defaults)), "actual saved background selection has no note at normal power")
    lowPower = true; state.refresh()
    check(state.showsPauseNote(delivery: ClosedAppDelivery.current(defaults)), "actual saved background selection displays local low power explanation")
    lowPower = false; state.refresh()
    check(!state.showsPauseNote(delivery: ClosedAppDelivery.current(defaults)) && defaults.string(forKey: ClosedAppDelivery.key) == deliveryPreference && app.notifier.enabled == notificationsEnabled,
          "local power transitions preserve actual Demo app notification preferences")
    ClosedAppDelivery.set(.pushRelay, defaults)
    lowPower = true; state.refresh()
    check(!state.showsPauseNote(delivery: ClosedAppDelivery.current(defaults)), "actual saved push selection is not described as background refresh")
    // The local power reader is an explicit device-input fixture, not a Demo Gateway field or an OS scheduling test.
}
