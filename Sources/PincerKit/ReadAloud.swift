import AVFoundation
import Foundation
import Observation

// Read Aloud: speaks one assistant message at a time, app-wide. Prefers the Gateway's voice
// (`tts.speak`) and falls back to this device's voice on any Gateway failure.

public protocol ReadAloudClipPlaying: AnyObject {
    /// Plays `clip` to the end; false when it can't be decoded or played (the caller falls back).
    @MainActor func play(_ clip: TTSClip) async -> Bool
    @MainActor func stop()
}

public protocol ReadAloudLocalSpeaking: AnyObject {
    /// Speaks `text` to the end; false when speech failed. `voice` is an AVSpeechSynthesisVoice identifier.
    @MainActor func speak(_ text: String, voice: String?, rate: Float) async -> Bool
    @MainActor func stop()
}

public enum ReadAloudSettings {
    public static let sourceKey = "pincer.readAloud.source"
    public static let autoReadKey = "pincer.readAloud.autoRead"
    public static let deviceVoiceKey = "pincer.readAloud.deviceVoice"
    public static let rateKey = "pincer.readAloud.rate"
    public static let sourceAutomatic = "automatic"
    public static let sourceDevice = "device"
    public static let rateRange: ClosedRange<Float> = 0.3 ... 0.7
    public static let gatewayTextLimit = 4000
    public static let gatewayTimeout: Duration = .seconds(15)
}

@MainActor @Observable
public final class ReadAloudController {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing(String)
        case speaking(String)
    }

    public enum Source: Equatable, Sendable {
        case gateway(String?)
        case device
    }

    public static let shared = ReadAloudController()

    public private(set) var phase: Phase = .idle
    public private(set) var lastSource: Source?

    @ObservationIgnored private let clipPlayer: ReadAloudClipPlaying
    @ObservationIgnored private let localSpeaker: ReadAloudLocalSpeaking
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gatewayTimeout: Duration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(clipPlayer: ReadAloudClipPlaying? = nil, localSpeaker: ReadAloudLocalSpeaking? = nil,
                defaults: UserDefaults = .standard, gatewayTimeout: Duration = ReadAloudSettings.gatewayTimeout)
    {
        self.clipPlayer = clipPlayer ?? AVClipPlayer()
        self.localSpeaker = localSpeaker ?? AVLocalSpeaker()
        self.defaults = defaults
        self.gatewayTimeout = gatewayTimeout
    }

    public var activeMessageId: String? {
        switch self.phase {
        case .idle: nil
        case let .preparing(id), let .speaking(id): id
        }
    }

    public var isActive: Bool { self.phase != .idle }

    public func isActive(_ id: String) -> Bool { self.activeMessageId == id }

    /// Speaks `text` for `messageId`, or stops if that message is already being read.
    public func toggle(messageId: String, text: String, gateway: GatewayVoiceModel?) {
        if self.isActive(messageId) { self.stop(); return }
        self.start(messageId: messageId, text: text, gateway: gateway)
    }

    /// Speaks `text`, replacing anything already being read.
    public func start(messageId: String, text: String, gateway: GatewayVoiceModel?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        self.cancelCurrent()
        self.generation += 1
        let generation = self.generation
        self.phase = .preparing(messageId)
        self.task = Task { [weak self] in
            await self?.run(messageId: messageId, text: text, gateway: gateway, generation: generation)
        }
    }

    public func stop() {
        self.cancelCurrent()
        self.generation += 1
        self.phase = .idle
    }

    private func cancelCurrent() {
        self.task?.cancel()
        self.task = nil
        self.clipPlayer.stop()
        self.localSpeaker.stop()
    }

    private var usesGatewayVoice: Bool {
        self.defaults.string(forKey: ReadAloudSettings.sourceKey) != ReadAloudSettings.sourceDevice
    }

    private var deviceRate: Float {
        let stored = self.defaults.object(forKey: ReadAloudSettings.rateKey) as? Double
        let rate = stored.map(Float.init) ?? AVSpeechUtteranceDefaultSpeechRate
        return min(max(rate, ReadAloudSettings.rateRange.lowerBound), ReadAloudSettings.rateRange.upperBound)
    }

    private func run(messageId: String, text: String, gateway: GatewayVoiceModel?, generation: Int) async {
        defer { if generation == self.generation { self.phase = .idle } }
        if self.usesGatewayVoice, let gateway { await gateway.loadStatusIfNeeded() }
        guard generation == self.generation, !Task.isCancelled else { return }
        if self.usesGatewayVoice, let gateway, gateway.canSpeak {
            let limited = SpeechText.truncated(text, limit: ReadAloudSettings.gatewayTextLimit)
            if let clip = await self.fetchClip(limited, from: gateway), !clip.isHeaderless, generation == self.generation {
                self.lastSource = .gateway(clip.provider)
                self.phase = .speaking(messageId)
                if await self.clipPlayer.play(clip) { return }
                guard generation == self.generation, !Task.isCancelled else { return }
            }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        self.lastSource = .device
        self.phase = .speaking(messageId)
        let voice = self.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey).flatMap { $0.isEmpty ? nil : $0 }
        _ = await self.localSpeaker.speak(text, voice: voice, rate: self.deviceRate)
    }

    /// The Gateway's audio, or nil on any failure or after the timeout.
    private func fetchClip(_ text: String, from gateway: GatewayVoiceModel) async -> TTSClip? {
        let timeout = self.gatewayTimeout
        let (stream, results) = AsyncStream.makeStream(of: TTSClip?.self)
        let speak = Task { @MainActor in results.yield(try? await gateway.speak(text)) }
        // Detached so the timeout still fires while the main actor is busy.
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            results.yield(nil)
        }
        defer {
            speak.cancel()
            timer.cancel()
            results.finish()
        }
        for await clip in stream { return clip }
        return nil
    }

    /// Plays a short sample with the device voice (Settings → Read Aloud → Test).
    public func testDeviceVoice(_ sample: String) {
        self.cancelCurrent()
        self.generation += 1
        let generation = self.generation
        self.phase = .preparing("test")
        let voice = self.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey).flatMap { $0.isEmpty ? nil : $0 }
        let rate = self.deviceRate
        self.task = Task { [weak self] in
            guard let self else { return }
            self.lastSource = .device
            self.phase = .speaking("test")
            _ = await self.localSpeaker.speak(sample, voice: voice, rate: rate)
            if generation == self.generation { self.phase = .idle }
        }
    }
}

// MARK: AVFoundation

enum ReadAloudAudioSession {
    static func activate() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

@MainActor
final class AVClipPlayer: NSObject, ReadAloudClipPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    /// The player whose callbacks count; a stopped player's late callbacks must not end a newer clip.
    private var playerId: ObjectIdentifier?
    private var continuation: CheckedContinuation<Bool, Never>?

    func play(_ clip: TTSClip) async -> Bool {
        self.stop()
        guard let player = try? AVAudioPlayer(data: clip.data, fileTypeHint: clip.fileTypeHint) else { return false }
        ReadAloudAudioSession.activate()
        player.delegate = self
        self.player = player
        self.playerId = ObjectIdentifier(player)
        guard player.prepareToPlay(), player.play() else {
            self.player = nil
            ReadAloudAudioSession.deactivate()
            return false
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        self.playerId = nil
        self.player?.stop()
        self.player = nil
        self.finish(true)
    }

    private func finish(_ success: Bool) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        ReadAloudAudioSession.deactivate()
        continuation.resume(returning: success)
    }

    private func ended(_ id: ObjectIdentifier, success: Bool) {
        guard id == self.playerId else { return }
        self.playerId = nil
        self.player = nil
        self.finish(success)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.ended(id, success: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.ended(id, success: false) }
    }
}

@MainActor
final class AVLocalSpeaker: NSObject, ReadAloudLocalSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance whose callbacks count; a stopped utterance's late didCancel must not end a newer one.
    private var currentUtterance: ObjectIdentifier?
    private var continuation: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        self.synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        self.stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voice, let resolved = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = resolved
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        ReadAloudAudioSession.activate()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.currentUtterance = ObjectIdentifier(utterance)
            self.synthesizer.speak(utterance)
        }
    }

    func stop() {
        self.currentUtterance = nil
        if self.synthesizer.isSpeaking || self.synthesizer.isPaused { self.synthesizer.stopSpeaking(at: .immediate) }
        self.finish(true)
    }

    private func finish(_ success: Bool) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        ReadAloudAudioSession.deactivate()
        continuation.resume(returning: success)
    }

    private func ended(_ id: ObjectIdentifier) {
        guard id == self.currentUtterance else { return }
        self.currentUtterance = nil
        self.finish(true)
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
