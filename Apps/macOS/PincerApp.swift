import PincerUI
import SwiftUI

@main
struct PincerApp: App {
    @NSApplicationDelegateAdaptor(NotificationAppDelegate.self) private var delegate

    init() { PincerIntentsSetup.install() }

    var body: some Scene {
        PincerScene()
    }
}
