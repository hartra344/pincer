#if os(macOS)
import AppKit
import PincerKit
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct NotificationLastCheckedMacHostedTests {
    @Test func fixedSavedTimestampChangesActualRenderedLabel() async throws {
        let scratch = ScratchDefaults()
        scratch.defaults.set(Date().addingTimeInterval(-2), forKey: "pincer.refresh.lastRun")
        scratch.defaults.set("Up to date", forKey: "pincer.refresh.lastResult")
        let saved = BackgroundRefreshLastCheck(defaults: scratch.defaults)
        let host = NSHostingView(rootView: NotificationLastCheckedValue(saved: saved))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let clock = ContinuousClock()
        let baselineDeadline = clock.now.advanced(by: .seconds(15))
        var initial: String?
        while clock.now < baselineDeadline {
            try Task.checkCancellation()
            let labels = Self.actualLabels(host)
            if labels.count == 1 { initial = labels.first; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let baseline = try #require(initial, "Actual unique timestamp and result label must be accessible")
        let changeDeadline = clock.now.advanced(by: .seconds(15))
        var changed = false
        while clock.now < changeDeadline {
            try Task.checkCancellation()
            let labels = Self.actualLabels(host)
            if labels.count == 1, let current = labels.first, current != baseline {
                changed = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changed, "Actual fixed-input relative timestamp must update within 15 seconds")
    }

    /// Public AppKit accessibility getters only; bounded against aggregate/cyclic trees.
    private static func actualLabels(_ root: NSObject) -> Set<String> {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        func get(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
            return unsafeBitCast(implementation, to: Getter.self)(object, selector)?.takeUnretainedValue()
        }
        var stack: [(NSObject, Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var labels = Set<String>()
        while let (object, depth) = stack.popLast(), visited.count < 512 {
            guard depth <= 32, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityLabel", "accessibilityValue"] {
                if let text = get(object, name) as? String,
                   !text.isEmpty, text.contains("Up to date"), text != "Up to date" {
                    labels.insert(text)
                }
            }
            if let children = get(object, "accessibilityChildren") as? [NSObject] {
                for child in children.prefix(max(0, 512 - visited.count - stack.count)) { stack.append((child, depth + 1)) }
            }
        }
        return labels
    }
}
#endif
