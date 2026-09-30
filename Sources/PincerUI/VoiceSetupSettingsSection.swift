import PincerKit
import SwiftUI

/// Section 5: the provider's voice settings (speed, stability, similarity, style, speaker boost).
struct VoiceSetupSettingsSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var draft = TTSVoiceSettings.elevenLabsDefault

    private var saved: TTSVoiceSettings { self.model.setups[self.provider]?.voiceSettings ?? .elevenLabsDefault }

    var body: some View {
        Section {
            self.slider(L("Speed"), value: self.$draft.speed, range: 0.5 ... 2, format: "%.2f×")
            self.slider(L("Stability"), value: self.$draft.stability, range: 0 ... 1, format: "%.2f")
            self.slider(L("Similarity boost"), value: self.$draft.similarityBoost, range: 0 ... 1, format: "%.2f")
            self.slider(L("Style"), value: self.$draft.style, range: 0 ... 1, format: "%.2f")
            Toggle(L("Speaker boost"), isOn: self.$draft.useSpeakerBoost)
                .disabled(!self.editable)
            if self.editable {
                Button(L("Save Voice Settings")) {
                    let value = self.draft
                    Task { await self.setup.run { try await self.model.saveVoiceSettings(value, provider: self.provider) } }
                }
                .disabled(self.draft == self.saved)
                Button(L("Reset to Defaults")) { self.draft = .elevenLabsDefault }
                    .disabled(self.draft == .elevenLabsDefault)
            }
        } header: {
            Text("Voice Settings", bundle: .module)
        }
        .task(id: self.saved) { self.draft = self.saved }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range) { Text(title) }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .disabled(!self.editable)
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
