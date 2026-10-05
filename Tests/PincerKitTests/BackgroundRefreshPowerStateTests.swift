import Testing
@testable import PincerKit

@MainActor @Suite struct BackgroundRefreshPowerStateTests {
    @Test func currentPowerStateOnlyExplainsBackgroundDelivery() {
        var lowPower = true
        let state = BackgroundRefreshPowerState(read: { lowPower })
        #expect(state.showsPauseNote(delivery: .backgroundRefresh))
        #expect(!state.showsPauseNote(delivery: .pushRelay) && !state.showsPauseNote(delivery: .off))
        lowPower = false; state.refresh()
        #expect(!state.showsPauseNote(delivery: .backgroundRefresh))
        lowPower = true; state.refresh()
        #expect(state.showsPauseNote(delivery: .backgroundRefresh))
    }
}
