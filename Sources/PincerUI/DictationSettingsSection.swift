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
                Label(L("On-device dictation isn't available for \(support.language)."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Dictation", bundle: .module)
        } footer: {
            Text("Dictation keeps your voice on this device. Without it, Apple may use its servers when your language has no on-device model.", bundle: .module)
        }
    }
}
