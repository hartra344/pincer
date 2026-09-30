import PincerKit
import SwiftUI

/// Settings → Conversation: keep dictation on this device (#463).
struct DictationSettingsSection: View {
    @AppStorage(DictationPreferences.onDeviceOnlyKey) private var onDeviceOnly = DictationPreferences.onDeviceOnlyDefault
    @State private var support = SpeechDictationEngine.onDeviceSupport()

    var body: some View {
        Section {
            Toggle(isOn: self.$onDeviceOnly) {
                Text("On-device only", bundle: .module)
            }
            if let support, !support.supported {
                Label(L("On-device dictation isn't available for \(support.language), so dictation won't work while this is on."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Dictation", bundle: .module)
        } footer: {
            Text("When on, your speech is recognized on this device and isn't sent to Apple. When off, Apple's servers may be used for languages that don't have an on-device model.", bundle: .module)
        }
    }
}
