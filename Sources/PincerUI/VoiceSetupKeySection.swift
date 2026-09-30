import PincerKit
import SwiftUI

/// Section 2: the provider's API key. The key is sent to the Gateway and is never stored by Pincer.
struct VoiceSetupKeySection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var key = ""
    @State private var checking = false
    @State private var check: KeyCheck?
    @State private var confirmingRemove = false

    private enum KeyCheck: Equatable {
        case working
        case failed(String)
        case saved
    }

    private var badgeFailed: Bool { if case .error = self.model.badge(for: self.provider) { return true } else { return false } }
    private var keys: TTSProviderKeys { TTSProviderKeys.forProvider(self.provider) }
    private var name: String { self.model.displayName(for: self.provider) }
    private var notResolving: Bool { self.model.keyIsNotResolving(self.provider) }
    private var sourceText: String { self.model.keySourceText(for: self.provider) }

    var body: some View {
        Section {
            if self.keys.apiKey == nil {
                Text("No key needed", bundle: .module).foregroundStyle(.secondary)
            } else {
                VoiceStackedRow(title: L("Current key")) {
                    Text(self.sourceText)
                        .foregroundStyle(self.notResolving ? Color.red : Color.secondary)
                }
                if self.editable { self.entry }
                if self.editable, self.model.canRemoveKey(self.provider) { self.removeButton }
                self.checkLine
                VoiceScopedMessage(setup: self.setup, scope: "key")
                if self.setup.keySavedProvider == self.provider {
                    VoiceUseProviderButton(model: self.model, setup: self.setup, provider: self.provider, prominent: true)
                }
            }
        } header: {
            Text("API Key", bundle: .module)
        } footer: {
            if self.keys.apiKey != nil {
                Text("The key is saved on the Gateway, not in Pincer. Pincer keeps it in memory only while this page is open, to list your voices.", bundle: .module)
            }
        }
    }

    @ViewBuilder private var entry: some View {
        APIKeyField(title: L("API key"), prompt: L("Paste API key"), text: self.$key, onSubmit: self.save)
        Button(L("Save Key"), action: self.save)
            .disabled(self.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.checking)
    }

    private var removeButton: some View {
        Button(L("Remove Key…"), role: .destructive) { self.confirmingRemove = true }
            .disabled(self.checking)
            .confirmationDialog(String(format: L("Remove the %@ key from the Gateway?"), self.name), isPresented: self.$confirmingRemove,
                                titleVisibility: .visible) {
                Button(L("Remove Key"), role: .destructive, action: self.remove)
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(String(format: L("The Gateway can't use %@ until you add a key again. Replies fall back to the next provider or this device's voice."), self.name))
            }
    }

    private func remove() {
        self.check = nil
        self.setup.keySavedProvider = nil
        Task {
            guard await self.setup.run("key", { try await self.model.removeKey(provider: self.provider) }) else { return }
            self.setup.notice = L("Key removed")
            self.setup.keyGeneration += 1
            AccessibilityNotification.Announcement(L("Key removed")).post()
        }
    }

    @ViewBuilder private var checkLine: some View {
        if self.checking {
            HStack { ProgressView().controlSize(.small); Text("Checking key…", bundle: .module).foregroundStyle(.secondary) }
        } else if let check = self.check, !(check == .working && self.badgeFailed) {
            switch check {
            case .working:
                Label(L("Key saved and working"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .saved:
                Label(L("Key saved. Run Test Voice to check it."), systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case let .failed(message):
                Label(String(format: L("%@ rejected the key: %@"), self.name, message), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private func save() {
        let value = self.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !self.checking else { return }
        self.key = ""
        self.check = nil
        self.setup.keySavedProvider = nil
        Task {
            guard await self.setup.run("key", { try await self.model.saveKey(value, provider: self.provider) }) else { return }
            self.setup.keySavedProvider = self.provider
            self.setup.keyGeneration += 1
            self.checking = true
            self.check = await self.verify()
            self.checking = false
            if let check = self.check {
                let text: String
                switch check {
                case .working: text = L("Key saved and working")
                case .saved: text = L("Key saved")
                case let .failed(message): text = message
                }
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    /// `tts.convert` with the explicit provider, so a working fallback can't hide a bad key.
    private func verify() async -> KeyCheck {
        switch await self.model.checkProvider(self.provider) {
        case .working: .working
        case let .rejected(message): .failed(message)
        case .unavailable: .saved
        }
    }
}
