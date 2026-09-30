import PincerKit
import SwiftUI

/// Gateway Settings → Voice: the Gateway's text-to-speech provider and persona (`tts.*`), and whether
/// it speaks every channel reply. Read Aloud in Pincer uses `tts.speak` and needs none of these.
struct VoiceSettingsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var setup = VoiceSetupController()

    private var model: GatewayVoiceModel { self.gateway.voice }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        Form {
            if let status = model.status {
                self.content(model, status)
            } else if model.isLoading {
                Section { ProgressView() }
            } else if !connected {
                Section { } footer: { Text("Connect to the Gateway to see its voice settings.", bundle: .module) }
            }
            if let message = (self.setup.messageScope == nil ? self.setup.error : nil) ?? model.loadError {
                Section { Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            } else if self.setup.messageScope == nil, let notice = self.setup.notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .disabled(self.setup.busy)
        .navigationTitle(L("Voice"))
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(!connected || model.isLoading)
            }
        }
        .task(id: connected) { if connected { await model.refresh() } }
        .onDisappear { self.setup.stop() }
    }

    @ViewBuilder private func content(_ model: GatewayVoiceModel, _ status: TTSStatus) -> some View {
        let provider = self.setup.selectedProvider ?? status.provider
        let keys = TTSProviderKeys.forProvider(provider)
        let editable = model.canConfigure
        VoiceSetupStatusSection(model: model, status: status)
        VoiceSetupProviderSection(model: model, setup: self.setup, status: status, selected: provider,
                                   hideUseButton: self.setup.keySavedProvider == provider)
        if !editable {
            Section { FullManagementBadge { self.navigator.destination = .connection } }
        }
        if !provider.isEmpty {
            VoiceSetupKeySection(model: model, setup: self.setup, provider: provider, editable: editable)
            if keys.model != nil {
                VoiceSetupModelSection(model: model, setup: self.setup, provider: provider, editable: editable)
            }
            if keys.voice != nil {
                VoiceSetupVoiceSection(model: model, setup: self.setup, provider: provider, editable: editable)
            }
            if keys.voiceSettings != nil {
                VoiceSetupSettingsSection(model: model, setup: self.setup, provider: provider, editable: editable)
            }
        }
        VoiceSetupTestSection(model: model, setup: self.setup)
        Section {
            Picker(L("Persona"), selection: Binding(get: { model.activePersona ?? "" }, set: { id in self.apply { try await model.setPersona(id.isEmpty ? nil : id) } })) {
                Text("None", bundle: .module).tag("")
                ForEach(model.personas) { Text($0.displayName).tag($0.id) }
            }
            Toggle(L("Speak Replies on Channels"), isOn: Binding(get: { status.enabled }, set: { on in self.apply { try await model.setAutoSpeakChannels(on) } }))
        } header: {
            Text("Persona & Channels", bundle: .module)
        } footer: {
            Text("Speak Replies on Channels is gateway-wide: the Gateway attaches spoken audio to every reply it sends on channels like Discord or Telegram, for everyone. It doesn't affect Read Aloud in Pincer. To always use this device's own voice for Read Aloud, change the Voice option in Settings → Read Aloud.", bundle: .module)
        }
        .disabled(!model.canWrite)
        if !model.canWrite {
            Section { } footer: { Text("This device doesn't have write access, so voice settings are read-only.", bundle: .module) }
        }
    }

    private func apply(_ change: @escaping @MainActor () async throws -> Void) {
        Task { await self.setup.run { try await change(); return nil } }
    }
}
