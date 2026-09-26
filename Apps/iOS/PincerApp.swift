import PincerKit
import PincerUI
import SwiftUI
import UIKit

@main
struct PincerApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var delegate

    var body: some Scene {
        PincerScene()
    }
}

/// Installs the notification delegate before launch finishes (so a notification that launched the
/// app is handled) and hands the APNs token to `PushRegistrar`.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        Notifier.shared.activate()
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[Pincer] APNs registration failed: %@", error.localizedDescription)
    }
}
