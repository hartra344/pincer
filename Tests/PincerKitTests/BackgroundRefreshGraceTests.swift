import Foundation
import Testing
@testable import PincerKit

@Suite("Background refresh grace period")
struct BackgroundRefreshGraceTests {
    @Test func liveReplyWhileInactiveSuppressesNextRefresh() {
        let defaults = BackgroundRefreshTests.defaults()
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        let gateway = UUID()
        let store = BackgroundRefreshCursorStore(defaults: defaults)
        store.save(BackgroundRefreshCursor(activityMs: 1000), for: gateway)

        let staleRow = 2000.0
        Notifier.advanceRefreshCursor(
            gateway, activityMs: max(staleRow, Date().timeIntervalSince1970 * 1000), appIsActive: false, defaults: defaults)

        let newer = BackgroundRefreshTests.row("agent:main:one", activity: Date().timeIntervalSince1970 * 1000 - 500)
        let plan = BackgroundRefreshPlanner.plan(
            snapshot: BackgroundRefreshSnapshot(sessions: [newer]), cursor: store.cursor(for: gateway),
            filter: BackgroundRefreshFilter(), gatewayId: gateway, gatewayName: "Home")
        #expect(plan.requests.isEmpty)
    }

    @Test func activeAppOrOtherModesLeaveTheCursorAlone() {
        let defaults = BackgroundRefreshTests.defaults()
        let gateway = UUID()
        let store = BackgroundRefreshCursorStore(defaults: defaults)
        store.save(BackgroundRefreshCursor(activityMs: 1000), for: gateway)

        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        Notifier.advanceRefreshCursor(gateway, activityMs: 5000, appIsActive: true, defaults: defaults)
        ClosedAppDelivery.set(.pushRelay, defaults)
        Notifier.advanceRefreshCursor(gateway, activityMs: 5000, appIsActive: false, defaults: defaults)
        #expect(store.cursor(for: gateway)?.activityMs == 1000)
    }

    @Test func approvalAndQuestionIdsAreRecorded() {
        let defaults = BackgroundRefreshTests.defaults()
        ClosedAppDelivery.set(.backgroundRefresh, defaults)
        let gateway = UUID()
        let store = BackgroundRefreshCursorStore(defaults: defaults)
        store.save(BackgroundRefreshCursor(activityMs: 1000), for: gateway)
        Notifier.advanceRefreshCursor(gateway, approvalId: "a1", appIsActive: false, defaults: defaults)
        Notifier.advanceRefreshCursor(gateway, questionId: "q1", appIsActive: false, defaults: defaults)
        #expect(store.cursor(for: gateway)?.approvalIds == ["a1"])
        #expect(store.cursor(for: gateway)?.questionIds == ["q1"])
    }
}
