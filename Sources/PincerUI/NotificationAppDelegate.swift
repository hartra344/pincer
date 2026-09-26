#if os(macOS)
import AppKit
import PincerKit

/// Installs the notification delegate before launch finishes, so acting on a notification left in
/// Notification Center after Pincer quit launches it and still resolves the approval.
public final class NotificationAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.activate()
    }
}
#endif
