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
    private var current: String? { self.model.setups[self.provider]?.model }

    private var selection: Binding<String> {
        Binding {
            if self.choosingCustom { return Self.customTag }
            guard let current = self.current, !current.isEmpty else { return "" }
            return self.options.contains { $0.id == current } ? current : Self.customTag
        } set: { value in
            if value == Self.customTag {
                self.choosingCustom = true
                self.custom = self.current ?? ""
            } else if !value.isEmpty {
                self.choosingCustom = false
                Task { await self.setup.run { try await self.model.saveModel(value, provider: self.provider) } }
            }
        }
    }

    var body: some View {
        Section {
            Picker(L("Model"), selection: self.selection) {
                if self.current == nil { Text("Provider default", bundle: .module).tag("") }
                ForEach(self.options) { Text($0.name).tag($0.id) }
                Text("Custom…", bundle: .module).tag(Self.customTag)
            }
            .disabled(!self.editable)
            if self.selection.wrappedValue == Self.customTag {
                TextField(L("Model ID"), text: self.$custom, prompt: Text("e.g. eleven_v4_turbo"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(!self.editable)
                if self.editable {
                    Button(L("Save Model")) {
                        let id = self.custom.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { if await self.setup.run({ try await self.model.saveModel(id, provider: self.provider) }) { self.choosingCustom = false } }
                    }
                    .disabled(self.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.custom == self.current)
                }
            }
        } header: {
            Text("Model", bundle: .module)
        } footer: {
            if let field = TTSProviderKeys.forProvider(self.provider).model {
                Text("Saved as `\(field)` in the Gateway's voice config.")
            }
        }
    }
}
