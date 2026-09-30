import AVFAudio
import Observation
import PincerKit
import Speech
import SwiftUI

/// `DictationEngine` on Apple's Speech framework: the microphone feeds an `SFSpeechAudioBufferRecognitionRequest`
/// (on-device whenever the recognizer supports it), and every partial transcript goes to the model.
///
/// The system calls the permission, tap, recognition and notification callbacks on its own threads, so they're
/// all built in `nonisolated` helpers and hop to the main actor explicitly.
@MainActor @Observable
final class SpeechDictationEngine: NSObject, DictationEngine, SFSpeechRecognizerDelegate {
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private lazy var audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastText = ""
    /// Mirrors the recognizer, so the button appears and disappears as availability changes.
    private var recognizerAvailable = false

    var isAvailable: Bool { self.recognizerAvailable }

    override init() {
        super.init()
        self.recognizer = Self.makeRecognizer()
        self.recognizer?.delegate = self
        self.recognizerAvailable = self.recognizer?.isAvailable ?? false
    }

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        if let recognizer = SFSpeechRecognizer(locale: .current) { return recognizer }
        return Locale.preferredLanguages.first.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
    }

    /// Whether the recognizer for the current language can run on-device, and that language's name; nil when
    /// there is no recognizer at all.
    static func onDeviceSupport() -> (language: String, supported: Bool)? {
        guard let recognizer = makeRecognizer() else { return nil }
        return (Self.languageName(recognizer), recognizer.supportsOnDeviceRecognition)
    }

    private static func languageName(_ recognizer: SFSpeechRecognizer) -> String {
        let identifier = recognizer.locale.identifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in self.recognizerAvailable = available }
    }

    // MARK: Permission

    nonisolated private static func speechStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func micGranted() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func authorize() async -> DictationIssue? {
        // A prompt the person just declined needs no explanation; one declined earlier points to Settings.
        let askedBefore = SFSpeechRecognizer.authorizationStatus() != .notDetermined
            && AVAudioApplication.shared.recordPermission != .undetermined
        switch await Self.speechStatus() {
        case .authorized: break
        case .restricted: return .speechRestricted
        default: return askedBefore ? .speechDenied : .declined
        }
        guard await Self.micGranted() else { return askedBefore ? .micDenied : .declined }
        if ReadAloudSupport.isVoiceOverRunning {
            // Said before the microphone opens, so it isn't transcribed.
            AccessibilityNotification.Announcement(L("Listening")).post()
            try? await Task.sleep(for: .milliseconds(800))
        }
        return nil
    }

    // MARK: Listening

    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        self.cancel()
        // Only one thing speaks or listens at a time.
        ReadAloudController.shared.stop()
        if self.recognizer == nil { self.recognizer = Self.makeRecognizer() }
        guard let recognizer = self.recognizer else { throw DictationIssue.unavailable }
        let onDeviceOnly = DictationPreferences.onDeviceOnly
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDeviceOnly, !onDevice { throw DictationIssue.onDeviceUnavailable(language: Self.languageName(recognizer)) }
        // `isAvailable` also reflects the network, which an on-device model doesn't need.
        guard recognizer.isAvailable || (onDeviceOnly && onDevice) else { throw DictationIssue.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDeviceOnly || onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = self.audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.teardownAudio()
            throw DictationIssue.failed(L("No microphone is available."))
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(for: request))
        self.audioEngine.prepare()
        do {
            try self.audioEngine.start()
        } catch {
            self.teardownAudio()
            throw DictationIssue.failed(L("Dictation couldn't use the microphone."))
        }
        self.request = request
        self.lastText = ""
        self.task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] outcome in
            guard let self, self.task != nil else { return }
            switch outcome {
            case let .text(text, isFinal):
                self.lastText = text
                onPartial(text, isFinal)
            case let .failure(issue):
                onError(issue)
            case .ignorable:
                // The task ended without a usable result (nothing heard, or cancelled): wrap up quietly.
                onPartial(self.lastText, true)
            }
        })
        self.observe(onPartial: onPartial)
    }

    /// The microphone changed or the system took the audio away: finish with what we have.
    private func observe(onPartial: @escaping @MainActor (String, Bool) -> Void) {
        let finish: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.task != nil else { return }
                onPartial(self.lastText, true)
            }
        }
        var names: [(Notification.Name, AnyObject?)] = [(.AVAudioEngineConfigurationChange, self.audioEngine)]
        #if os(iOS)
        names.append((AVAudioSession.interruptionNotification, AVAudioSession.sharedInstance()))
        #endif
        self.observers = names.map { name, object in Self.observer(name, object: object, finish) }
    }

    nonisolated private static func observer(_ name: Notification.Name, object: AnyObject?, _ action: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in action() }
    }

    nonisolated private static func tap(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        let sink = BufferSink(request)
        return { buffer, _ in sink.append(buffer) }
    }

    private enum Outcome: Sendable {
        case text(String, isFinal: Bool)
        case failure(DictationIssue)
        case ignorable
    }

    nonisolated private static func handler(_ deliver: @escaping @MainActor @Sendable (Outcome) -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let outcome: Outcome
            if let result {
                outcome = .text(result.bestTranscription.formattedString, isFinal: result.isFinal)
            } else if let error {
                outcome = Self.isIgnorable(error) ? .ignorable : .failure(.failed(L("Dictation stopped unexpectedly. Try again.")))
            } else {
                return
            }
            Task { @MainActor in deliver(outcome) }
        }
    }

    /// "No speech detected", cancellation and similar codes from the Speech framework's two error domains.
    nonisolated private static func isIgnorable(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == "kAFAssistantErrorDomain" || error.domain == "kLSRErrorDomain" else { return false }
        return [1110, 203, 216, 301].contains(error.code)
    }

    func stop() {
        self.stopAudio()
        self.request?.endAudio()
    }

    func cancel() {
        self.stopAudio()
        self.task?.cancel()
        self.task = nil
        self.request = nil
    }

    private func stopAudio() {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.observers = []
        self.teardownAudio()
    }

    private func teardownAudio() {
        if self.audioEngine.isRunning { self.audioEngine.stop() }
        self.audioEngine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Forwards microphone buffers from the audio thread; the request accepts appends from any thread.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { self.request.append(buffer) }
}
