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

    static let defaultVoiceId = "pMsXgVXv3BLzUgSXRplE"

    /// A raw ID is already visible in the Voice ID field below.
    private var showsCurrentRow: Bool {
        guard let current = self.current else { return true }
        return self.model.voiceDisplay(current, provider: self.provider) != current
    }

    private var isElevenLabs: Bool { self.provider == "elevenlabs" }
    private var current: String? { self.model.setups[self.provider]?.voice.flatMap { $0.isEmpty ? nil : $0 } }

    private var shown: [ElevenLabsVoice] {
        let query = self.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self.model.voices }
        return self.model.voices.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.category ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Section {
            if self.showsCurrentRow { LabeledContent(L("Voice")) { self.currentVoice } }
            if self.isElevenLabs { self.browser }
            #if os(iOS)
            Text("Voice ID", bundle: .module).font(.subheadline).foregroundStyle(.secondary)
            #endif
            HStack {
                TextField(L("Voice ID"), text: self.$voiceId, prompt: Text("Paste a voice ID", bundle: .module))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(!self.editable)
                    .onSubmit { self.save(self.voiceId) }
                if self.editable {
                    Button(L("Use")) { self.save(self.voiceId) }
                        .disabled(self.voiceId.trimmingCharacters(in: .whitespaces).isEmpty || self.voiceId == self.current)
                }
            }
            VoiceScopedMessage(setup: self.setup, scope: "voice")
        } header: {
            Text("Voice", bundle: .module)
        }
        .task(id: self.current) { self.voiceId = self.current ?? "" }
        .task(id: "\(self.provider)-\(self.setup.keyGeneration)") { if self.isElevenLabs { await self.load(key: nil) } }
    }

    @ViewBuilder private var currentVoice: some View {
        let text = self.model.voiceDisplay(self.current, provider: self.provider)
        if let current = self.current, text == current {
            Text(current).font(.callout.monospaced()).textSelection(.enabled)
        } else {
            Text(text)
        }
    }

    @ViewBuilder private var browser: some View {
        if self.needsKey {
            Text("Paste your API key above to browse your voices.", bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
            APIKeyField(title: L("API key (only used to list voices)"), prompt: L("Paste API key"), text: self.$pastedKey)
            Button(L("Load Voices")) { Task { await self.load(key: self.pastedKey) } }
                .disabled(self.pastedKey.isEmpty || self.loading)
        } else if self.loading && self.model.voices.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Loading voices…", bundle: .module).foregroundStyle(.secondary) }
        }
        if let loadError {
            Label(loadError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
        if !self.model.voices.isEmpty {
            #if os(macOS)
            TextField(L("Search voices"), text: self.$search).autocorrectionDisabled()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(self.shown) { voice in
                        VoiceListRow(voice: voice, current: self.current, setup: self.setup, editable: self.editable, choose: self.save)
                            .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .frame(height: 220)
            #else
            NavigationLink {
                VoiceBrowserPage(voices: self.model.voices, current: self.current, setup: self.setup, editable: self.editable, choose: self.save)
            } label: {
                Text("Browse Voices", bundle: .module)
            }
            #endif
        }
    }

    private func save(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        Task { await self.setup.run("voice") { try await self.model.saveVoice(id, provider: self.provider) } }
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
        } catch TTSSetupError.invalidKey {
            self.needsKey = true
            self.loadError = L("Couldn't load voices: ElevenLabs says the key is invalid.")
        } catch {
            self.loadError = String(format: L("Couldn't load voices: %@"), (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// One ElevenLabs voice: a ▶ preview (one plays at a time) and a tap target that chooses it.
struct VoiceListRow: View {
    let voice: ElevenLabsVoice
    let current: String?
    let setup: VoiceSetupController
    let editable: Bool
    let choose: (String) -> Void

    var body: some View {
        let selected = self.voice.id == self.current
        let playing = self.setup.playingId == self.voice.id
        HStack {
            Button { self.setup.playPreview(self.voice) } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(self.voice.previewURL == nil)
            .accessibilityLabel(playing ? L("Stop Preview") : String(format: L("Preview %@"), self.voice.name))
            Button { if self.editable { self.choose(self.voice.id) } } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(self.voice.name).foregroundStyle(.primary)
                        if let category = self.voice.category { Text(category).font(.caption).foregroundStyle(.secondary) }
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
}

/// iOS: the searchable voice list, pushed from the Voice section.
struct VoiceBrowserPage: View {
    let voices: [ElevenLabsVoice]
    let current: String?
    let setup: VoiceSetupController
    let editable: Bool
    let choose: (String) -> Void
    @State private var search = ""

    private var shown: [ElevenLabsVoice] {
        let query = self.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self.voices }
        return self.voices.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.category ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(self.shown) { voice in
            VoiceListRow(voice: voice, current: self.current, setup: self.setup, editable: self.editable, choose: self.choose)
        }
        .searchable(text: self.$search)
        .navigationTitle(L("Voice"))
        .onDisappear { self.setup.stop() }
    }
}
