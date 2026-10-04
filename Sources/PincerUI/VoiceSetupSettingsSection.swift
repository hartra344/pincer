import PincerKit
import SwiftUI

/// Section 5: the provider's voice settings (speed, stability, similarity, style, speaker boost).
/// Collapsed by default; a change is saved when the slider is released, never per tick.
struct VoiceSetupSettingsSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var draft = VoiceSettingsDraft()
    @State private var expanded = false

    init(model: GatewayVoiceModel, setup: VoiceSetupController, provider: String, editable: Bool,
         initialExpanded: Bool = false, draft: VoiceSettingsDraft? = nil) {
        self.model = model
        self.setup = setup
        self.provider = provider
        self.editable = editable
        self._expanded = State(initialValue: initialExpanded)
        self._draft = State(initialValue: draft ?? VoiceSettingsDraft())
    }

    private var saved: TTSVoiceSettings { self.model.setups[self.provider]?.voiceSettings ?? .elevenLabsDefault }

    var body: some View {
        Section {
            DisclosureGroup(L("Voice Settings"), isExpanded: self.$expanded) {
                self.slider(L("Speed"), value: self.binding(\.speed), range: 0.5 ... 2, percent: false)
                self.slider(L("Stability"), value: self.binding(\.stability), range: 0 ... 1, percent: true)
                self.slider(L("Similarity Boost"), value: self.binding(\.similarityBoost), range: 0 ... 1, percent: true)
                self.slider(L("Style"), value: self.binding(\.style), range: 0 ... 1, percent: true)
                Toggle(L("Speaker Boost"), isOn: self.binding(\.useSpeakerBoost))
                    .disabled(!self.editable)
                    .onChange(of: self.draft.value.useSpeakerBoost) { _, _ in self.commit() }
                VoiceScopedMessage(setup: self.setup, scope: "settings")
                if self.editable {
                    Button(L("Reset to Defaults")) {
                        self.draft.edit(.elevenLabsDefault)
                        self.commit()
                    }
                    .disabled(self.saved == .elevenLabsDefault && self.draft.value == .elevenLabsDefault)
                }
            }
        }
        .task(id: self.saved) { self.draft.updateSnapshot(self.saved) }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TTSVoiceSettings, Value>) -> Binding<Value> {
        Binding(get: { self.draft.value[keyPath: keyPath] }, set: { value in
            var next = self.draft.value
            next[keyPath: keyPath] = value
            self.draft.edit(next)
        })
    }

    private func commit() {
        guard let first = self.draft.commit() else { return }
        Task {
            var submission: VoiceSettingsDraft.Submission? = first
            while let current = submission {
                let succeeded = await self.setup.run("settings") {
                    try await self.model.saveVoiceSettings(current.value, provider: self.provider)
                }
                submission = self.draft.complete(current, acknowledged: succeeded ? self.saved : nil)
            }
        }
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
