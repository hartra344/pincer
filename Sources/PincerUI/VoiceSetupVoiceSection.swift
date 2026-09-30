import PincerKit
import SwiftUI

/// Section 4: the voice. ElevenLabs lists the account's voices with a preview; every provider can take a voice ID.
struct VoiceSetupVoiceSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    let editable: Bool
    @State private var search = ""
    @State private var voiceId = ""
    @State private var pastedKey = ""
    @State private var loadError: String?
    @State private var needsKey = false
    @State private var loading = false

    private var isElevenLabs: Bool { self.provider == "elevenlabs" }
    private var current: String? { self.model.setups[self.provider]?.voice }

    private var shown: [ElevenLabsVoice] {
        let query = self.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self.model.voices }
        return self.model.voices.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.category ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Section {
            if self.isElevenLabs { self.browser }
            HStack {
                TextField(L("Voice ID"), text: self.$voiceId, prompt: Text("Paste a voice ID", bundle: .module))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(!self.editable)
                if self.editable {
                    Button(L("Use")) { self.save(self.voiceId.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(self.voiceId.trimmingCharacters(in: .whitespaces).isEmpty || self.voiceId == self.current)
                }
            }
        } header: {
            Text("Voice", bundle: .module)
        } footer: {
            if let field = TTSProviderKeys.forProvider(self.provider).voice {
                Text("Saved as `\(field)` in the Gateway's voice config.")
            }
        }
        .task(id: self.current) {
            self.voiceId = self.current ?? ""
        }
        .task(id: self.provider) { if self.isElevenLabs { await self.load(key: nil) } }
    }

    @ViewBuilder private var browser: some View {
        if self.needsKey {
            Text("Paste your API key to browse voices, or paste a voice ID below.", bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
            SecureField(L("API key (only used to list voices)"), text: self.$pastedKey)
                .autocorrectionDisabled()
            Button(L("Load Voices")) { Task { await self.load(key: self.pastedKey) } }
                .disabled(self.pastedKey.isEmpty || self.loading)
        } else if self.loading && self.model.voices.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Loading voices…", bundle: .module).foregroundStyle(.secondary) }
        }
        if let loadError {
            Label(loadError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
        if !self.model.voices.isEmpty {
            TextField(L("Search voices"), text: self.$search)
                .autocorrectionDisabled()
            ForEach(self.shown) { voice in self.row(voice) }
        }
    }

    private func row(_ voice: ElevenLabsVoice) -> some View {
        let selected = voice.id == self.current
        return HStack {
            Button { self.setup.playPreview(voice) } label: {
                Image(systemName: self.setup.playingId == voice.id ? "stop.circle.fill" : "play.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(voice.previewURL == nil)
            .accessibilityLabel(self.setup.playingId == voice.id ? L("Stop preview") : String(format: L("Preview %@"), voice.name))
            Button { if self.editable { self.save(voice.id) } } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(voice.name).foregroundStyle(.primary)
                        if let category = voice.category { Text(category).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func save(_ id: String) {
        guard !id.isEmpty else { return }
        Task { await self.setup.run { try await self.model.saveVoice(id, provider: self.provider) } }
    }

    private func load(key: String?) async {
        self.loading = true
        self.loadError = nil
        defer { self.loading = false }
        do {
            _ = try await self.model.listElevenLabsVoices(apiKey: key)
            self.needsKey = false
            self.pastedKey = ""
        } catch TTSSetupError.needsKey {
            self.needsKey = true
        } catch {
            self.needsKey = key != nil || self.needsKey
            self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
