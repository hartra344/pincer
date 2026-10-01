import AVFoundation
import Foundation
import Observation

// Read Aloud: speaks one assistant message at a time, app-wide. Prefers the Gateway's voice
// (`tts.speak`) and falls back to this device's voice on any Gateway failure.

public protocol ReadAloudClipPlaying: AnyObject {
    /// Plays `clip` to the end; false when it can't be decoded or played (the caller falls back).
    @MainActor func play(_ clip: TTSClip) async -> Bool
    @MainActor func stop()
    /// Gets `clip` ready ahead of its `play`, so there's no setup gap between chunks.
    @MainActor func prepare(_ clip: TTSClip)
}

public extension ReadAloudClipPlaying {
    @MainActor func prepare(_: TTSClip) {}
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
    /// Sent in `SpeechChunker` pieces, so this only guards against huge messages.
    public static let gatewayTextLimit = 20000
    public static let gatewayTimeout: Duration = .seconds(15)
    /// How many chunks past the one playing are requested from the Gateway (#562).
    public static let prefetchDepth = 3

    /// The device voice to show in a picker: the stored id when it's still available, else "" (the
    /// "Default" row), so the picker never has a selection that matches no row (#457).
    public static func displayedDeviceVoice(stored: String, available: [String]) -> String {
        available.contains(stored) ? stored : ""
    }
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

    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { self.systemIntegration?.phaseChanged(self.phase, title: self.nowPlayingTitle) } }
    }
    public private(set) var lastSource: Source?
    /// Why the last read used the device voice (or a different provider) instead of the selected Gateway
    /// voice; nil when the Gateway voice spoke as configured.
    public private(set) var lastFallback: TTSFallbackReason?
    /// The dictation in progress, if any. Read Aloud ends it before speaking, and auto-read stays quiet meanwhile.
    @ObservationIgnored weak var activeDictation: DictationModel?
    public var isDictating: Bool { self.activeDictation?.isActive == true }

    @ObservationIgnored private let clipPlayer: ReadAloudClipPlaying
    @ObservationIgnored private var localSpeaker: ReadAloudLocalSpeaking?
    package var hasCreatedSystemSpeaker: Bool { self.localSpeaker is AVLocalSpeaker }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gatewayTimeout: Duration
    /// Waits out a Gateway timeout; tests swap in a timer they fire themselves.
    @ObservationIgnored var gatewayTimer: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingTitle: String?
    @ObservationIgnored private var systemIntegration: ReadAloudSystemIntegrating?

    public init(clipPlayer: ReadAloudClipPlaying? = nil, localSpeaker: ReadAloudLocalSpeaking? = nil,
                defaults: UserDefaults = .standard, gatewayTimeout: Duration = ReadAloudSettings.gatewayTimeout)
    {
        self.clipPlayer = clipPlayer ?? AVClipPlayer()
        self.localSpeaker = localSpeaker
        self.defaults = defaults
        self.gatewayTimeout = gatewayTimeout
        #if os(iOS)
        // Only the real controller talks to the OS; tests inject fake players and drive `handle(_:)`.
        if clipPlayer == nil, localSpeaker == nil { self.systemIntegration = ReadAloudSystemIntegration(controller: self) }
        #endif
    }

    /// Ends the read for an interruption, unplugged output, lock-screen stop or expired background time.
    /// Never resumes on its own.
    public func handle(_ event: ReadAloudSystemEvent) {
        switch event {
        case .interruptionBegan, .oldDeviceUnavailable, .remoteStop, .backgroundTimeExpired:
            if self.isActive { self.stop() }
        }
    }

    public func handleAudioInterruptionBegan() { self.handle(.interruptionBegan) }
    public func handleRouteOldDeviceUnavailable() { self.handle(.oldDeviceUnavailable) }
    public func handleRemoteStop() { self.handle(.remoteStop) }

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
        self.activeDictation?.finish()
        self.cancelCurrent()
        self.generation += 1
        let generation = self.generation
        self.nowPlayingTitle = Self.nowPlayingTitle(for: text)
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
        self.localSpeaker?.stop()
    }

    private func deviceSpeaker() -> ReadAloudLocalSpeaking {
        if let localSpeaker = self.localSpeaker { return localSpeaker }
        let localSpeaker = AVLocalSpeaker()
        self.localSpeaker = localSpeaker
        return localSpeaker
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
        var fallback: TTSFallbackReason?
        if !self.usesGatewayVoice {
            fallback = .deviceOnlySetting
        } else if let gateway {
            if gateway.canSpeak {
                // NLTokenizer over a long reply is too slow for the main actor.
                let chunks = await Task.detached(priority: .userInitiated) {
                    SpeechChunker.chunks(SpeechText.truncated(text, limit: ReadAloudSettings.gatewayTextLimit))
                }.value
                guard generation == self.generation, !Task.isCancelled else { return }
                // While chunk n plays, chunk n+1 is fetched; each fetch has its own timeout (#562).
                // Requests run one after another, each starting as soon as the one before returns, and stay
                // up to `prefetchDepth` chunks ahead of playback so there's no gap between chunks.
                typealias Fetch = Task<(TTSClip?, TTSFallbackReason?), Never>
                var fetches: [Fetch] = []
                defer { fetches.forEach { $0.cancel() } }
                func requestAhead(of index: Int) {
                    while fetches.count < min(chunks.count, index + 1 + ReadAloudSettings.prefetchDepth) {
                        let previous = fetches.last
                        let chunk = chunks[fetches.count]
                        fetches.append(Task { @MainActor in
                            if let previous, await previous.value.0 == nil { return (nil, nil) }
                            guard !Task.isCancelled else { return (nil, nil) }
                            return await self.fetchClip(chunk, from: gateway)
                        })
                    }
                }
                var index = 0
                while index < chunks.count {
                    requestAhead(of: index)
                    let fetch = fetches[index]
                    let (clip, failure) = await withTaskCancellationHandler { await fetch.value } onCancel: { fetch.cancel() }
                    guard generation == self.generation, !Task.isCancelled else { return }
                    guard let clip, !clip.isHeaderless else {
                        fallback = failure ?? .other(L("The Gateway audio couldn't be played."))
                        break
                    }
                    if index == 0 {
                        self.lastSource = .gateway(clip.provider)
                        let selected = gateway.status?.provider
                        if let used = clip.provider, let selected, !selected.isEmpty, used != selected {
                            self.lastFallback = gateway.fallbackReasonForRead(selected: selected)
                        } else {
                            self.lastFallback = nil
                        }
                    }
                    self.phase = .speaking(messageId)
                    if index + 1 < fetches.count {
                        let next = fetches[index + 1]
                        Task { @MainActor [weak self] in
                            guard let clip = await next.value.0, !clip.isHeaderless, let self, generation == self.generation else { return }
                            self.clipPlayer.prepare(clip)
                        }
                    }
                    let played = await self.clipPlayer.play(clip)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    guard played else {
                        fallback = .other(L("The Gateway audio couldn't be played."))
                        break
                    }
                    index += 1
                }
                if index >= chunks.count { return }
                if index > 0 {
                    // Part of the message was already voiced by the Gateway: read only the rest on this device.
                    self.lastFallback = fallback
                    self.phase = .speaking(messageId)
                    let voice = self.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey).flatMap { $0.isEmpty ? nil : $0 }
                    _ = await self.deviceSpeaker().speak(chunks[index...].joined(separator: " "), voice: voice, rate: self.deviceRate)
                    return
                }
            } else {
                fallback = gateway.cannotSpeakReason
            }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        self.lastFallback = fallback
        self.lastSource = .device
        self.phase = .speaking(messageId)
        let voice = self.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey).flatMap { $0.isEmpty ? nil : $0 }
        _ = await self.deviceSpeaker().speak(text, voice: voice, rate: self.deviceRate)
    }

    /// The Gateway's audio, or why there is none (any failure, or the timeout).
    private func fetchClip(_ text: String, from gateway: GatewayVoiceModel) async -> (TTSClip?, TTSFallbackReason?) {
        let timeout = self.gatewayTimeout
        let wait = self.gatewayTimer
        let (stream, results) = AsyncStream.makeStream(of: (TTSClip?, TTSFallbackReason?).self)
        let speak = Task { @MainActor in
            do {
                results.yield((try await gateway.speak(text), nil))
            } catch {
                results.yield((nil, .other(GatewayVoiceModel.message(error))))
            }
        }
        // Detached so the timeout still fires while the main actor is busy.
        let timer = Task.detached {
            await wait(timeout)
            results.yield((nil, .other(L("The Gateway took too long to answer."))))
        }
        defer {
            speak.cancel()
            timer.cancel()
            results.finish()
        }
        for await result in stream { return result }
        return (nil, nil)
    }

    /// Plays a short sample with the device voice (Settings → Read Aloud → Test).
    public func testDeviceVoice(_ sample: String) {
        self.cancelCurrent()
        self.generation += 1
        let generation = self.generation
        self.nowPlayingTitle = Self.nowPlayingTitle(for: sample)
        self.phase = .preparing("test")
        let voice = self.defaults.string(forKey: ReadAloudSettings.deviceVoiceKey).flatMap { $0.isEmpty ? nil : $0 }
        let rate = self.deviceRate
        self.task = Task { [weak self] in
            guard let self else { return }
            self.lastSource = .device
            self.phase = .speaking("test")
            _ = await self.deviceSpeaker().speak(sample, voice: voice, rate: rate)
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
    private var prepared: (clip: TTSClip, player: AVAudioPlayer)?
    /// The player whose callbacks count; a stopped player's late callbacks must not end a newer clip.
    private var playerId: ObjectIdentifier?
    private var continuation: CheckedContinuation<Bool, Never>?

    func prepare(_ clip: TTSClip) {
        guard self.prepared?.clip != clip,
              let player = try? AVAudioPlayer(data: clip.data, fileTypeHint: clip.fileTypeHint), player.prepareToPlay() else { return }
        self.prepared = (clip, player)
    }

    func play(_ clip: TTSClip) async -> Bool {
        self.stopCurrent()
        let ready = self.prepared?.clip == clip ? self.prepared?.player : nil
        self.prepared = nil
        guard let player = ready ?? (try? AVAudioPlayer(data: clip.data, fileTypeHint: clip.fileTypeHint)) else { return false }
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
        let keptSession = self.prepared != nil && self.continuation == nil
        self.prepared = nil
        if keptSession { ReadAloudAudioSession.deactivate() }
        self.stopCurrent()
    }

    private func stopCurrent() {
        self.playerId = nil
        self.player?.stop()
        self.player = nil
        self.finish(true)
    }

    private func finish(_ success: Bool) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        // Keep the session (and other audio ducked) when the next chunk is already waiting.
        if self.prepared == nil { ReadAloudAudioSession.deactivate() }
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
        // Share the app's playback session so speech keeps going with the app in the background.
        #if os(iOS)
        self.synthesizer.usesApplicationAudioSession = true
        #endif
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
