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
        defer { window.isHidden = true; window.rootViewController = nil }
        func eligibleLabels() -> Set<String> {
            var visited = Set<ObjectIdentifier>(), labels = Set<String>(), count = 0
            func walk(_ object: NSObject, depth: Int) {
                guard depth <= 32, count < 512, visited.insert(ObjectIdentifier(object)).inserted else { return }
                count += 1
                if let view = object as? UIView {
                    if let label = view.accessibilityLabel { labels.insert(label) }
                    for element in view.accessibilityElements ?? [] {
                        if let object = element as? NSObject { walk(object, depth: depth + 1) }
                    }
                    for child in view.subviews { walk(child, depth: depth + 1) }
                } else if let element = object as? UIAccessibilityElement, let label = element.accessibilityLabel {
                    labels.insert(label)
                }
            }
            walk(host.view, depth: 0)
            return Set(labels.filter { $0.contains("Up to date") && $0 != "Up to date" })
        }
        var first: String?
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while first == nil && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let eligible = eligibleLabels()
            if eligible.count == 1 { first = eligible.first }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try #require(first, "Actual rendered accessibility label unavailable: app-host qualification blocker")
        var changed = false
        let changeDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !changed && ContinuousClock.now < changeDeadline {
            try Task.checkCancellation()
            let eligible = eligibleLabels()
            changed = eligible.count == 1 && eligible.first != initial
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changed, "Actual relative label must update while saved date, suffix and root view stay fixed")
        #expect(BackgroundRefreshLastCheck(defaults: scratch.defaults) == saved)
    }
}
#endif
