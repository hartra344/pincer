import PincerKit

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
