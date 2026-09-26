import PincerUI
import SwiftUI

@main
struct PincerApp: App {
    @NSApplicationDelegateAdaptor(NotificationAppDelegate.self) private var delegate

    var body: some Scene {
        PincerScene()
    }
}
