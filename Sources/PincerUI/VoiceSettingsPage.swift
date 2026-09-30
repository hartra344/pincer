import PincerKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Gateway Settings → Voice: the Gateway's text-to-speech provider and persona (`tts.*`), and whether
/// it speaks every channel reply. Read Aloud in Pincer uses `tts.speak` and needs none of these.
struct VoiceSettingsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var setup = VoiceSetupController()
    @State private var confirmingAuto = false
    @State private var pendingAuto = TTSAutoMode.off

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
            self.autoSpeakRow(model, status)
        } header: {
            Text("Persona & Channels", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speak Replies on Channels is gateway-wide. It controls when the Gateway attaches spoken audio to replies on channels like Discord or Telegram, for everyone. It doesn't affect Read Aloud in Pincer. To always use this device's own voice for Read Aloud, change the Voice option in Settings → Read Aloud.", bundle: .module)
                Text("“Only After Voice Messages” and “Only When Tagged” are set in the Gateway's config or /tts preferences; Pincer can only switch replies Off or Always.", bundle: .module)
            }
        }
        .disabled(!model.canWrite)
        if !model.canWrite {
            Section { } footer: { Text("This device doesn't have write access, so voice settings are read-only.", bundle: .module) }
        }
    }

    @ViewBuilder private func autoSpeakRow(_ model: GatewayVoiceModel, _ status: TTSStatus) -> some View {
        let current = model.autoMode
        let currentName = current?.displayName ?? String(format: L("Unknown (%@)"), status.auto)
        let selection = Binding<String>(get: { status.auto.lowercased() }, set: { self.choose($0, model) })
        LabeledContent(L("Speak Replies on Channels")) {
            Menu {
                Picker(L("Speak Replies on Channels"), selection: selection) {
                    if current != .off, current != .always { Text(currentName).tag(status.auto.lowercased()) }
                    Text(TTSAutoMode.off.displayName).tag(TTSAutoMode.off.rawValue)
                    Text(TTSAutoMode.always.displayName).tag(TTSAutoMode.always.rawValue)
                }
            } label: {
                Text(currentName)
            }
        }
        .confirmationDialog(String(format: L("Replace “%@” with “%@”?"), currentName, self.pendingAuto.displayName),
                            isPresented: self.$confirmingAuto, titleVisibility: .visible) {
            Button(self.pendingAuto == .always ? L("Switch to Always") : L("Turn Off"), role: .destructive) {
                self.apply { try await model.setAutoSpeakChannels(self.pendingAuto == .always) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("To go back to %@, edit the Gateway's config or use /tts."), currentName))
        }
    }

    private func choose(_ raw: String, _ model: GatewayVoiceModel) {
        guard let mode = TTSAutoMode(rawValue: raw), mode == .off || mode == .always, model.autoMode != mode else { return }
        if model.setAutoSpeakNeedsConfirmation(mode == .always) {
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            self.pendingAuto = mode
            self.confirmingAuto = true
        } else {
            self.apply { try await model.setAutoSpeakChannels(mode == .always) }
        }
    }

    private func apply(_ change: @escaping @MainActor () async throws -> Void) {
        Task { await self.setup.run { try await change(); return nil } }
    }
}
