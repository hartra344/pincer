import PincerKit
import SwiftUI

/// Gateway Settings → Voice: the Gateway's text-to-speech provider and persona (`tts.*`), and whether
/// it speaks every channel reply. Read Aloud in Pincer uses `tts.speak` and needs none of these.
struct VoiceSettingsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var error: String?
    @State private var busy = false

    private var model: GatewayVoiceModel { self.gateway.voice }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Form {
            if let status = model.status {
                Section {
                    Picker(L("Provider"), selection: Binding(get: { status.provider }, set: { id in self.apply { try await model.setProvider(id) } })) {
                        ForEach(self.providerRows(status)) { row in
                            Text(row.configured ? row.name : "\(row.name) · \(L("Not Configured"))")
                                .tag(row.id)
                                .selectionDisabled(!row.configured && row.id != status.provider)
                        }
                    }
                    Picker(L("Persona"), selection: Binding(get: { model.activePersona ?? "" }, set: { id in self.apply { try await model.setPersona(id.isEmpty ? nil : id) } })) {
                        Text("None", bundle: .module).tag("")
                        ForEach(model.personas) { Text($0.displayName).tag($0.id) }
                    }
                } header: {
                    Text("Gateway Voice", bundle: .module)
                } footer: {
                    Text("Read Aloud uses this voice when this device is allowed to and the Gateway has a voice set up. To always use this device's own voice, change the Voice option in the Read Aloud section of Settings.", bundle: .module)
                }
                Section {
                    Toggle(L("Speak Replies on Channels"), isOn: Binding(get: { status.enabled }, set: { on in self.apply { try await model.setAutoSpeakChannels(on) } }))
                } footer: {
                    Text("This is gateway-wide: the Gateway attaches spoken audio to every reply it sends on channels like Discord or Telegram, for everyone. It doesn't affect Read Aloud in Pincer.", bundle: .module)
                }
                .disabled(!model.canWrite)
                if !model.canWrite {
                    Section { } footer: { Text("This device doesn't have write access, so voice settings are read-only.", bundle: .module) }
                }
            } else if model.isLoading {
                Section { ProgressView() }
            } else if !connected {
                Section { } footer: { Text("Connect to the Gateway to see its voice settings.", bundle: .module) }
            }
            if let message = self.error ?? model.loadError {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(self.busy)
        .navigationTitle(L("Voice"))
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(!connected || model.isLoading)
            }
        }
        .task(id: connected) { if connected { await model.refresh() } }
    }

    private func providerRows(_ status: TTSStatus) -> [TTSProvider] {
        if !self.model.providers.isEmpty { return self.model.providers }
        return status.providerStates.map { TTSProvider(id: $0.id, name: $0.label, configured: $0.configured) }
    }

    private func apply(_ change: @escaping @MainActor () async throws -> Void) {
        self.error = nil
        self.busy = true
        Task {
            do { try await change() } catch { self.error = GatewayVoiceModel.message(error) }
            self.busy = false
        }
    }
}
