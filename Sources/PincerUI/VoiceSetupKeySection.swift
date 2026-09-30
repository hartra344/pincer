import PincerKit
import SwiftUI

/// Section 2: the provider's API key. The key is sent to the Gateway and is never stored by Pincer.
struct VoiceSetupKeySection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var key = ""

    private var keys: TTSProviderKeys { TTSProviderKeys.forProvider(self.provider) }

    private var sourceText: String {
        switch self.model.setups[self.provider]?.keySource ?? .none {
        case .none:
            self.model.badge(for: self.provider) == .needsKey ? L("Not set") : L("Provided by the Gateway's environment")
        case .inline: L("Saved in the Gateway's config")
        case .redacted: L("Saved on the Gateway")
        case let .secretRef(source, _, id):
            switch source {
            case "store": String(format: L("Stored in Gateway secrets as %@"), id)
            case "env": String(format: L("From environment variable %@"), id)
            default: String(format: L("From %@ %@"), source, id)
            }
        }
    }

    var body: some View {
        Section {
            LabeledContent(L("Current key")) {
                Text(self.sourceText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if self.editable {
                SecureField(L("API key"), text: self.$key, prompt: Text("Paste your API key", bundle: .module))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(L("Save Key")) {
                    let value = self.key
                    Task { if await self.setup.run({ try await self.model.saveKey(value, provider: self.provider) }) { self.key = "" } }
                }
                .disabled(self.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("API Key", bundle: .module)
        } footer: {
            if self.editable {
                Text("Sent to the Gateway over your connection and stored there. Pincer doesn't keep it.", bundle: .module)
            }
        }
    }
}
