import AVFoundation
import Observation
import PincerKit
import SwiftUI

/// Shared state for the Gateway Voice page's sections: the one busy/notice/error line, the provider being
/// set up, and audio playback for voice previews and Test voice.
@MainActor @Observable
final class VoiceSetupController {
    var busy = false
    var notice: String?
    var error: String?
    /// The provider whose setup is showing (may differ from the Gateway's active provider).
    var selectedProvider: String?
    private(set) var playingId: String?
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var clipPlayer: AVAudioPlayer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    /// Runs `work`, reporting the outcome or error on the page. Returns whether it succeeded.
    @discardableResult
    func run(_ work: @MainActor () async throws -> ConfigApplyOutcome?) async -> Bool {
        self.error = nil
        self.notice = nil
        self.busy = true
        defer { self.busy = false }
        do {
            self.notice = try await work()?.message
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? GatewayVoiceModel.message(error)
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
        self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player.play()
    }

    func play(_ clip: TTSClip) {
        self.stop()
        self.prepareSession()
        guard let player = try? AVAudioPlayer(data: clip.data, fileTypeHint: clip.fileExtension) else { return }
        self.clipPlayer = player
        player.play()
    }

    func stop() {
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

/// ✓ Ready / ⚠ Needs key / ✗ Error: symbol, colour and text, so it doesn't rely on colour alone.
struct VoiceBadge: View {
    let badge: TTSProviderBadge

    private var content: (symbol: String, text: String, color: Color) {
        switch self.badge {
        case .ready: ("checkmark.circle.fill", L("Ready"), .green)
        case .needsKey: ("exclamationmark.triangle.fill", L("Needs key"), .orange)
        case .error: ("xmark.octagon.fill", L("Error"), .red)
        }
    }

    var body: some View {
        let content = self.content
        Label(content.text, systemImage: content.symbol)
            .font(.callout)
            .foregroundStyle(content.color)
            .labelStyle(.titleAndIcon)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.accessibilityText(content.text))
    }

    private func accessibilityText(_ text: String) -> String {
        if case let .error(message) = self.badge { return "\(text): \(message)" }
        return text
    }
}

/// The footer used by every setup section when the connection can't change the Gateway's voice.
struct VoiceReadOnlyFooter: View {
    let reason: String?

    var body: some View {
        if let reason { Text(reason) }
    }
}
