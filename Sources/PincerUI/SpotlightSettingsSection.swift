import PincerKit
import SwiftUI

/// Settings → Search: whether chats appear in system Spotlight search.
struct SpotlightSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Spotlight.enabledKey) private var enabled = Spotlight.enabledDefault
    @AppStorage(Spotlight.includeMessagesKey) private var includeMessages = Spotlight.includeMessagesDefault

    var body: some View {
        Section {
            Toggle(L("Show Chats in Spotlight"), isOn: self.$enabled)
            Toggle(L("Include Message Text"), isOn: self.$includeMessages)
                .disabled(!self.enabled)
        } header: {
            Text("Search", bundle: .module)
        } footer: {
            Text("Spotlight always shows chat titles. Message text is the last few cached messages and stays on this device.", bundle: .module)
        }
        .onChange(of: self.enabled) { self.app.spotlightPreferencesChanged() }
        .onChange(of: self.includeMessages) { self.app.spotlightPreferencesChanged() }
    }
}
