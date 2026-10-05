#if os(iOS) && DEBUG
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func backgroundRefreshNoteTracksActualPowerNotification() async throws {
        var lowPower = false
        let power = BackgroundRefreshPowerState(read: { lowPower }), center = NotificationCenter()
        let controller = UIHostingController(rootView: Form {
            BackgroundRefreshPowerNote(delivery: .backgroundRefresh, power: power, center: center)
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try #require(await eventually { controller.view.window != nil })
        #expect(!power.showsPauseNote(delivery: .backgroundRefresh))
        lowPower = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try #require(await eventually { power.isLowPowerModeEnabled })
        #expect(power.showsPauseNote(delivery: .backgroundRefresh))
        #expect(!power.showsPauseNote(delivery: .pushRelay) && !power.showsPauseNote(delivery: .off))
        lowPower = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try #require(await eventually { !power.isLowPowerModeEnabled })
        #expect(!power.showsPauseNote(delivery: .backgroundRefresh))
    }
}
#endif
