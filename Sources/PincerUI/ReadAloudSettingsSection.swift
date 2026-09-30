import AVFoundation
import PincerKit
import SwiftUI

/// Settings → Read Aloud: where the voice comes from, the device voice and speed, and auto-read.
struct ReadAloudSettingsSection: View {
    @AppStorage(ReadAloudSettings.sourceKey) private var source = ReadAloudSettings.sourceAutomatic
    @AppStorage(ReadAloudSettings.deviceVoiceKey) private var deviceVoice = ""
    @AppStorage(ReadAloudSettings.rateKey) private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage(ReadAloudSettings.autoReadKey) private var autoRead = false
    private let controller = ReadAloudController.shared

    private var voices: [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode().prefix(2)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    private var shownDeviceVoice: Binding<String> {
        Binding(get: { self.displayedVoice }, set: { self.deviceVoice = $0 })
    }

    /// The stored voice when this device still has it, otherwise System Default, so the picker is never blank.
    private var displayedVoice: String {
        ReadAloudSettings.displayedDeviceVoice(stored: self.deviceVoice, available: self.voices.map(\.identifier))
    }

    private var rateDescription: String {
        let range = ReadAloudSettings.rateRange
        let fraction = (Float(self.rate) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return "\(Int((fraction * 100).rounded())) \(L("percent"))"
    }

    var body: some View {
        SwiftUI.Section {
            Picker(L("Voice"), selection: self.$source) {
                Text("Automatic", bundle: .module).tag(ReadAloudSettings.sourceAutomatic)
                Text("This Device Only", bundle: .module).tag(ReadAloudSettings.sourceDevice)
            }
            ReadAloudGatewayVoiceRows()
            Picker(L("Device Voice"), selection: self.shownDeviceVoice) {
                Text("System Default", bundle: .module).tag("")
                ForEach(self.voices, id: \.identifier) { Text($0.name).tag($0.identifier) }
            }
            LabeledContent(L("Speaking Rate")) {
                Slider(value: self.$rate, in: Double(ReadAloudSettings.rateRange.lowerBound) ... Double(ReadAloudSettings.rateRange.upperBound)) {
                    Text("Speaking Rate", bundle: .module)
                } minimumValueLabel: {
                    Text("Slower", bundle: .module)
                } maximumValueLabel: {
                    Text("Faster", bundle: .module)
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityValue(self.rateDescription)
            }
            Toggle(L("Read New Replies Aloud"), isOn: self.$autoRead)
            Button(self.controller.isActive ? L("Stop") : L("Test Device Voice")) {
                if self.controller.isActive {
                    self.controller.stop()
                } else {
                    self.controller.testDeviceVoice(L("This is how Pincer will read your replies aloud."))
                }
            }
        } header: {
            Text("Read Aloud", bundle: .module)
        } footer: {
            Text("Speaks a reply from its context menu. Automatic uses the Gateway's voice when available. The device voice is used when the Gateway can't provide one. New replies are only read in the chat you're looking at, and not while VoiceOver is on.", bundle: .module)
        }
    }
}
