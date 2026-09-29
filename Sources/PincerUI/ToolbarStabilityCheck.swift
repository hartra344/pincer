#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// `PincerMacDev --toolbar-stability-check`: opens the demo, switches between chats and fails if
/// the window toolbar removes or re-adds an item on a switch. When that happens macOS redraws every
/// toolbar button, the sidebar's Organize and New Chat included, so they flash (#84, #262).
///
/// The usual cause is a per-chat `.id` on a full-size detail view or on the root of a toolbar item's
/// content; keep it inside a stable container instead (see CONTRIBUTING.md). Run it with
/// `PINCER_DEV_NAMESPACE` and `PINCER_KEYCHAIN=memory` so it leaves your own gateways alone.
@MainActor public enum ToolbarStabilityCheck {
    private static var added = 0
    private static var removed = 0

    public static func run(switches: Int = 8) async -> Int32 {
        let app = AppModel.shared
        let hadDemo = app.gateways.contains { $0.profile.isDemo }
        app.openDemo()
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.added += 1 }
            },
            center.addObserver(forName: NSToolbar.didRemoveItemNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.removed += 1 }
            },
        ]
        defer {
            observers.forEach(center.removeObserver)
            if !hadDemo, let demo = app.gateways.first(where: { $0.profile.isDemo }) { app.remove(demo.id) }
        }

        // The demo connects without a network; give the window and its chats time to appear.
        var keys: [String] = []
        var window: NSWindow?
        for _ in 0..<150 {
            keys = app.selectedGateway.map { Array($0.sessions.keys.sorted().prefix(4)) } ?? []
            window = NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
            if keys.count >= 2, window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let gateway = app.selectedGateway, keys.count >= 2, let window else {
            print("Toolbar stability: FAIL, the demo didn't show a window with at least two chats")
            return 2
        }

        gateway.selectedKey = keys[0]
        try? await Task.sleep(for: .seconds(1.5))
        var failures = 0
        for index in 1...switches {
            let before = self.itemIds(window)
            self.added = 0
            self.removed = 0
            gateway.selectedKey = keys[index % keys.count]
            try? await Task.sleep(for: .milliseconds(700))
            let after = self.itemIds(window)
            let replaced = before.subtracting(after).count
            if self.added + self.removed + replaced > 0 {
                failures += 1
                print("Toolbar stability: switch \(index) added \(self.added), removed \(self.removed), replaced \(replaced) toolbar items")
            }
        }
        print(failures == 0
            ? "Toolbar stability: OK, \(switches) chat switches kept every toolbar item"
            : "Toolbar stability: FAIL, \(failures) of \(switches) chat switches rebuilt toolbar items")
        return failures == 0 ? 0 : 1
    }

    private static func itemIds(_ window: NSWindow) -> Set<ObjectIdentifier> {
        Set((window.toolbar?.items ?? []).map(ObjectIdentifier.init))
    }
}
#endif
