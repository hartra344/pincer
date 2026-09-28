#if os(macOS)
import PincerKit
import SwiftUI

/// Settings → General → Menu Bar: show or hide the Pincer menu bar item. Off by default.
struct MenuBarSettingsSection: View {
    @AppStorage(MenuBarSettings.enabledKey) private var enabled = false

    var body: some View {
        Section {
            Toggle(isOn: self.$enabled) {
                Text("Show Pincer in the menu bar", bundle: .module)
                Text("Quick Capture, unread chats, approvals and gateway status, one click away.", bundle: .module)
            }
        } header: {
            Text("Menu Bar", bundle: .module)
        }
    }
}
#endif
