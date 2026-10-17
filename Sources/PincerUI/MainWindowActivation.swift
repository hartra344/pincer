#if os(macOS)
import AppKit
import SwiftUI

enum MainWindow {
    /// Raises the existing main window, or opens it if it was closed.
    @MainActor static func bringToFront(openWindow: OpenWindowAction) {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
#endif
