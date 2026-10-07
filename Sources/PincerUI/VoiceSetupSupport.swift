import AVFoundation
import Observation
import PincerKit
import SwiftUI

/// Shared state for the Gateway Voice page's sections: the one busy/notice/error line, the provider being
/// set up, and audio playback for voice previews and Test voice.
@MainActor @Observable
final class VoiceSetupController {
    private let operations = VoiceSetupOperationTracker()
    private let testCompletion = VoiceTestCompletion()
    #if DEBUG
    var testPlaybackOverride: ((TTSClip) -> Void)?
    #endif
    @discardableResult
    func startTestVoice(model: GatewayVoiceModel, sample: String, finished: @escaping () -> Void = {},
                        publish: @escaping (TTSTestResult) -> Void) -> Task<Void, Never> {
        self.testCompletion.start(model: model, sample: sample, publish: publish, finished: finished) { clip in
            #if DEBUG
            if let override = self.testPlaybackOverride { override(clip); return }
            #endif
            self.play(clip)
        }
    }

    var busy: Bool { self.operations.busy }
    var notice: String?
    var error: String?
    /// The section that triggered `notice`/`error` (nil: shown at the page bottom).
    var messageScope: String?
    /// Bumped when a key was saved, so the voice list reloads.
    var keyGeneration = 0
    var keySavedProvider: String?
    /// The provider whose setup is showing (may differ from the Gateway's active provider).
    var selectedProvider: String?
    #if DEBUG
    /// Read-only access to the actual item used by the registered completion observer.
    var currentPreviewItem: AVPlayerItem? { self.avPlayer?.currentItem }
    #endif
    private(set) var playingId: String?
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var clipPlayer: AVAudioPlayer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var playbackOwnership = VoicePlaybackOwnership()

    /// Runs `work`, reporting the outcome or error on the page. Returns whether it succeeded.
    @discardableResult
    func run(_ scope: String? = nil, _ work: @MainActor () async throws -> ConfigApplyOutcome?) async -> Bool {
        let operation = self.operations.begin()
        self.error = nil
        self.notice = nil
        self.messageScope = scope
        do {
            let result = try await work()
            if self.operations.finish(operation) { self.notice = result?.message }
            return true
        } catch {
            if self.operations.finish(operation) {
                self.error = (error as? LocalizedError)?.errorDescription ?? GatewayVoiceModel.message(error)
            }
            return false
        }
    }

    func playPreview(_ voice: ElevenLabsVoice) {
        guard let url = voice.previewURL else { return }
        if self.playingId == voice.id { self.stop(); return }
        self.stop()
        self.prepareSession()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.avPlayer = player
        self.playingId = voice.id
        let playback = self.playbackOwnership.begin()
        self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackOwnership.owns(playback) else { return }
                self.stop()
            }
        }
        player.play()
    }

    func play(_ clip: TTSClip) {
        self.stop()
        self.prepareSession()
        guard let player = try? AVAudioPlayer(data: clip.data, fileTypeHint: clip.fileExtension) else { return }
        self.clipPlayer = player
        self.playingId = Self.testId
        let playback = self.playbackOwnership.begin()
        player.play()
        Task { @MainActor [weak self] in
            while let self, self.playbackOwnership.owns(playback), self.clipPlayer === player, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let self, self.playbackOwnership.owns(playback), self.clipPlayer === player { self.stop() }
        }
    }

    static let testId = "test-voice"

    func stop() {
        self.testCompletion.invalidate()
        self.playbackOwnership.invalidate()
        self.avPlayer?.pause()
        self.avPlayer = nil
        self.clipPlayer?.stop()
        self.clipPlayer = nil
        self.playingId = nil
        if let observer = self.endObserver { NotificationCenter.default.removeObserver(observer) }
        self.endObserver = nil
    }

    private func prepareSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

/// Ready / Needs Key / Not Working: symbol, colour and text, so it doesn't rely on colour alone.
struct VoiceBadge: View {
    let badge: TTSProviderBadge

    private var content: (symbol: String, text: String, color: Color) {
        switch self.badge {
        case .ready: ("checkmark.circle.fill", L("Ready"), .green)
        case .needsKey: ("exclamationmark.triangle.fill", L("Needs Key"), .orange)
        case .error: ("xmark.octagon.fill", L("Not Working"), .red)
        }
    }

    var body: some View {
        let content = self.content
        Label(content.text, systemImage: content.symbol)
            .font(.callout)
            .foregroundStyle(content.color)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

/// The secondary "In Use" capsule for the provider the Gateway is speaking with.
struct VoiceInUseTag: View {
    var body: some View {
        Text("In Use", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}

/// Makes `provider` the Gateway's voice. Shared by the provider list and the key section.
struct VoiceUseProviderButton: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let provider: String
    var prominent = false

    var body: some View {
        if let status = self.model.status, status.provider != self.provider, self.model.badge(for: self.provider) == .ready {
            let title = String(format: L("Use %@ for Gateway Voice"), self.model.displayName(for: self.provider))
            let button = Button(title) {
                let id = self.provider
                Task { await self.setup.run("provider") { try await self.model.setProvider(id); return nil } }
            }
            .disabled(!self.model.canWrite)
            if self.prominent { button.buttonStyle(.borderedProminent) } else { button }
        }
    }
}

extension GatewayVoiceModel {
    /// The display name of a model id ("Eleven v4 Turbo"), or the id itself when it isn't a known one.
    func modelDisplayName(_ id: String?, provider: String) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return self.modelOptions(for: provider).first { $0.id == id }?.name ?? id
    }
}

/// The outcome of the last change, next to the control that made it.
struct VoiceScopedMessage: View {
    let setup: VoiceSetupController
    let scope: String

    var body: some View {
        if self.setup.messageScope == self.scope {
            if let error = self.setup.error {
                Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            } else if let notice = self.setup.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A label with a value: beside each other on macOS, the value under the label on iOS where it has room to wrap.
struct VoiceStackedRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
            self.content.multilineTextAlignment(.leading).font(.callout)
        }
        #else
        LabeledContent(self.title) { self.content.multilineTextAlignment(.trailing) }
        #endif
    }
}
