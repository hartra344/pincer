#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor struct NotificationLastCheckedHostedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_LAST_CHECKED_APP_HOSTED"] == "1"), .timeLimit(.minutes(2)))
    func actualSavedTimestampUpdatesWithoutChangingInputs() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let fixedDate = Date().addingTimeInterval(-2)
        scratch.defaults.set(fixedDate, forKey: "pincer.refresh.lastRun")
        scratch.defaults.set("Up to date", forKey: "pincer.refresh.lastResult")
        let saved = BackgroundRefreshLastCheck(defaults: scratch.defaults)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "Actual active app scene required")
        let host = UIHostingController(rootView: NotificationLastCheckedValue(saved: saved))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func labels(_ view: UIView) -> [String] {
            var result = view.accessibilityLabel.map { [$0] } ?? []
            for element in view.accessibilityElements ?? [] {
                if let element = element as? UIAccessibilityElement, let label = element.accessibilityLabel { result.append(label) }
                else if let child = element as? UIView { result += labels(child) }
            }
            for child in view.subviews { result += labels(child) }
            return result
        }
        var first: String?
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while first == nil && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            first = labels(host.view).first { $0.contains("Up to date") && $0 != "Up to date" }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try #require(first, "Actual rendered accessibility label unavailable: app-host qualification blocker")
        var changed = false
        let changeDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !changed && ContinuousClock.now < changeDeadline {
            try Task.checkCancellation()
            changed = labels(host.view).contains { $0.contains("Up to date") && $0 != initial }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changed, "Actual relative label must update while saved date, suffix and root view stay fixed")
        #expect(BackgroundRefreshLastCheck(defaults: scratch.defaults) == saved)
    }
}
#endif
