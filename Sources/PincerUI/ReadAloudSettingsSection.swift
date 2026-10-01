import AVFoundation
import PincerKit
import SwiftUI

/// Settings → Read Aloud: where the voice comes from, the device voice and speed, and auto-read.
struct ReadAloudSettingsSection: View {
    let catalog: AppleDeviceSpeechCatalog
    @AppStorage(ReadAloudSettings.sourceKey) private var source = ReadAloudSettings.sourceAutomatic
    @AppStorage(ReadAloudSettings.deviceVoiceKey) private var deviceVoice = ""
    @AppStorage(ReadAloudSettings.rateKey) private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage(ReadAloudSettings.autoReadKey) private var autoRead = false
    private let controller = ReadAloudController.shared

    init(catalog: AppleDeviceSpeechCatalog = .shared) {
        self.catalog = catalog
    }

    private var voices: [DeviceSpeechVoice] { self.catalog.state.snapshot?.voices ?? [] }

    private var shownDeviceVoice: Binding<String> {
        Binding(get: { self.displayedVoice }, set: { self.deviceVoice = $0 })
    }

    /// The stored voice when this device still has it, otherwise System Default, so the picker is never blank.
    private var displayedVoice: String {
        if self.catalog.state.snapshot == nil || self.catalog.state.isRefreshing {
            return self.deviceVoice
        }
        return ReadAloudSettings.displayedDeviceVoice(stored: self.deviceVoice, available: self.voices.map(\.id))
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
                if !self.deviceVoice.isEmpty,
                   (self.catalog.state.snapshot == nil || self.catalog.state.isRefreshing),
                   !self.voices.contains(where: { $0.id == self.deviceVoice })
                {
                    Text("Loading voices…", bundle: .module).tag(self.deviceVoice)
                }
                ForEach(self.voices) { Text($0.name).tag($0.id) }
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
            Text("Tap Listen under a reply, or use Read Last Reply Aloud (its keyboard shortcut) from the command palette. Press Esc or tap the Speaking pill to stop. Automatic uses the Gateway's voice when available. The device voice is used when the Gateway can't provide one. New replies are only read in the chat you're looking at, and not while VoiceOver is on.", bundle: .module)
        }
        .task { self.catalog.refresh() }
    }
}
