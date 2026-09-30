import PincerKit
import SwiftUI

/// Section 3: the provider's model. Known models are a picker; anything else is a custom ID.
struct VoiceSetupModelSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var custom = ""
    @State private var choosingCustom = false

    private static let customTag = "\u{0}custom"

    private var options: [TTSModelOption] { self.model.modelOptions(for: self.provider) }
    private var current: String? { self.model.setups[self.provider]?.model.flatMap { $0.isEmpty ? nil : $0 } }
    /// What the Gateway uses when none is set.
    private var defaultId: String? { self.provider == "elevenlabs" ? "eleven_multilingual_v2" : nil }
    private var isCustom: Bool {
        self.choosingCustom || (self.current.map { id in !self.options.contains { $0.id == id } } ?? false)
    }

    private var selection: Binding<String> {
        Binding {
            if self.isCustom { return Self.customTag }
            return self.current ?? self.defaultId ?? ""
        } set: { value in
            if value == Self.customTag {
                self.choosingCustom = true
                self.custom = self.current ?? ""
            } else if !value.isEmpty, value != self.current {
                self.choosingCustom = false
                Task { await self.setup.run("model") { try await self.model.saveModel(value, provider: self.provider) } }
            }
        }
    }

    var body: some View {
        Section {
            Picker(L("Model"), selection: self.selection) {
                if self.defaultId == nil, self.current == nil { Text("Default", bundle: .module).tag("") }
                ForEach(self.options) { option in
                    Text(option.id == self.defaultId ? String(format: L("%@ (Default)"), option.name) : option.name).tag(option.id)
                }
                if self.isCustom, let current = self.current, !self.choosingCustom {
                    Text(String(format: L("Custom: %@"), current)).tag(Self.customTag)
                } else {
                    Text("Custom…", bundle: .module).tag(Self.customTag)
                }
            }
            .disabled(!self.editable)
            if self.isCustom {
                TextField(L("Model ID"), text: self.$custom, prompt: Text("Model ID, e.g. eleven_v4_turbo", bundle: .module))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(!self.editable)
                    .onSubmit(self.saveCustom)
                    .task(id: self.current) { if !self.choosingCustom { self.custom = self.current ?? "" } }
                if self.editable {
                    Button(L("Save Model"), action: self.saveCustom)
                        .disabled(self.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.custom == self.current)
                }
            }
            if let ignored = self.model.setups[self.provider]?.ignoredModel, self.current == nil {
                Label(String(format: L("The Gateway config has model \"%@\", which is ignored. Choose a model here to replace it."), ignored), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            VoiceScopedMessage(setup: self.setup, scope: "model")
        } header: {
            Text("Model", bundle: .module)
        }
    }

    private func saveCustom() {
        let id = self.custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != self.current else { return }
        Task { if await self.setup.run("model", { try await self.model.saveModel(id, provider: self.provider) }) { self.choosingCustom = false } }
    }
}
