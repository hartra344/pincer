#if os(iOS) && DEBUG
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func backgroundRefreshNoteTracksActualPowerNotification() async throws {
        var lowPower = false
        var readsOnMain = true, reads = 0
        let power = BackgroundRefreshPowerState(read: {
            readsOnMain = readsOnMain && Thread.isMainThread; reads += 1
            return lowPower
        }), center = NotificationCenter()
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let controller = UIHostingController(rootView: Form {
            NotificationSettingsSection(power: power, powerNotifications: center, initialDelivery: .backgroundRefresh, initialNotifications: app.notifier.enabled)
        }.environment(app))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try #require(await eventually { controller.view.window != nil && reads >= 2 })
        #expect(!power.showsPauseNote(delivery: .backgroundRefresh))
        lowPower = true
        await Task.detached { center.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }.value
        try #require(await eventually { power.isLowPowerModeEnabled })
        #expect(power.showsPauseNote(delivery: .backgroundRefresh))
        #expect(!power.showsPauseNote(delivery: .pushRelay) && !power.showsPauseNote(delivery: .off))
        lowPower = false
        await Task.detached { center.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }.value
        try #require(await eventually { !power.isLowPowerModeEnabled })
        #expect(!power.showsPauseNote(delivery: .backgroundRefresh))
        #expect(readsOnMain && reads >= 3, "Actual power reader stays on Main after background notification delivery")
    }
}
#endif
