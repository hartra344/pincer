import PincerKit
import SwiftUI

/// Section 5: the provider's voice settings (speed, stability, similarity, style, speaker boost).
/// Collapsed by default; a change is saved when the slider is released, never per tick.
struct VoiceSetupSettingsSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var draft = TTSVoiceSettings.elevenLabsDefault
    @State private var expanded = false

    private var saved: TTSVoiceSettings { self.model.setups[self.provider]?.voiceSettings ?? .elevenLabsDefault }

    var body: some View {
        Section {
            DisclosureGroup(L("Voice Settings"), isExpanded: self.$expanded) {
                self.slider(L("Speed"), value: self.$draft.speed, range: 0.5 ... 2, percent: false)
                self.slider(L("Stability"), value: self.$draft.stability, range: 0 ... 1, percent: true)
                self.slider(L("Similarity Boost"), value: self.$draft.similarityBoost, range: 0 ... 1, percent: true)
                self.slider(L("Style"), value: self.$draft.style, range: 0 ... 1, percent: true)
                Toggle(L("Speaker Boost"), isOn: self.$draft.useSpeakerBoost)
                    .disabled(!self.editable)
                    .onChange(of: self.draft.useSpeakerBoost) { _, _ in self.commit() }
                VoiceScopedMessage(setup: self.setup, scope: "settings")
                if self.editable {
                    Button(L("Reset to Defaults")) {
                        self.draft = .elevenLabsDefault
                        self.commit()
                    }
                    .disabled(self.saved == .elevenLabsDefault && self.draft == .elevenLabsDefault)
                }
            }
        }
        .task(id: self.saved) { self.draft = self.saved }
    }

    private func commit() {
        let value = self.draft
        guard value != self.saved else { return }
        Task { await self.setup.run("settings") { try await self.model.saveVoiceSettings(value, provider: self.provider) } }
    }

    private func display(_ value: Double, percent: Bool) -> String {
        percent ? "\(Int((value * 100).rounded()))%" : String(format: "%.1f×", value)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(self.display(value.wrappedValue, percent: percent)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in if !editing { self.commit() } } label: { Text(title) }
                .labelsHidden()
                .disabled(!self.editable)
                .accessibilityLabel(title)
                .accessibilityValue(percent ? String(format: L("%d percent"), Int((value.wrappedValue * 100).rounded())) : self.display(value.wrappedValue, percent: false))
        }
    }
}
