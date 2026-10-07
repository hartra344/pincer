import PincerKit
import PincerUI
import SwiftUI
import UIKit

@main
struct PincerApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var delegate

    init() {
        PincerIntentsSetup.install()
        #if DEBUG
        FirstRunTour.startIfRequested()
        #endif
    }

    var body: some Scene {
        PincerScene()
    }
}

/// Installs the notification delegate before launch finishes (so a notification that launched the
/// app is handled) and hands the APNs token to `PushRegistrar`. Approval actions resolve without a
/// scene: iOS may launch Pincer in the background just to deliver one.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        let notifier = Notifier.shared
        // Until a scene reports its phase; keeps a background launch from posting what push already delivers.
        notifier.appIsActive = application.applicationState != .background
        notifier.beginBackgroundActivity = { name, expired in BackgroundActivity(name: name, expired: expired).end }
        notifier.activate()
        application.registerForRemoteNotifications()
        BackgroundRefreshTask.register()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppModel.shared.saveOutboxesNow()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.setDeviceToken(deviceToken)
    }

    /// A relay push carries `content-available`: catch up briefly (badge, questions, replies the
    /// gateway didn't push). The completion handler runs exactly once, bounded by the refresh deadline.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        nonisolated(unsafe) let userInfo = userInfo
        nonisolated(unsafe) let handler = completionHandler
        let active = application.applicationState == .active
        MainHop.run {
            SilentPushRefreshRuns.shared.handle(userInfo, appIsActive: active) { result in
                let mapped: UIBackgroundFetchResult = switch result {
                case .newData: .newData
                case .noData: .noData
                case .failed: .failed
                }
                handler(mapped)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[Pincer] APNs registration failed: %@", error.localizedDescription)
    }
}

/// A `beginBackgroundTask` that ends once, when the work is done or the system's time runs out.
@MainActor
private final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String, expired: @escaping @MainActor () -> Void) {
        self.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { @Sendable [weak self] in
            MainHop.run {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard self.identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.identifier)
        self.identifier = .invalid
    }
}
