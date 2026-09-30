import Foundation
import Observation

// Dictation: live speech-to-text into the composer. This file is pure logic; the Speech framework
// engine lives in PincerUI behind `DictationEngine`, so it can be faked in tests.

/// Where dictated text goes in a draft: it replaces the previous partial result, so the text around it
/// (captured when dictation started) never changes.
public struct DictationSplice: Sendable, Equatable {
    public let before: String
    public let after: String

    /// `insertionOffset` counts characters from the start of `draft`; nil (or past the end) means the end.
    public init(draft: String, insertionOffset: Int?) {
        let offset = min(max(insertionOffset ?? draft.count, 0), draft.count)
        let index = draft.index(draft.startIndex, offsetBy: offset)
        self.before = String(draft[..<index])
        self.after = String(draft[index...])
    }

    /// The draft with `partial` inserted, spaced from its neighbours. An empty partial gives the original draft.
    public func applying(_ partial: String) -> String {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return self.before + self.after }
        var result = self.before
        if let last = self.before.last, !last.isWhitespace { result += " " }
        result += partial
        if let first = self.after.first, !first.isWhitespace, !first.isPunctuation { result += " " }
        return result + self.after
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle, requestingPermission, starting, listening, finishing
}

public enum DictationIssue: Equatable, Error, Sendable {
    case speechDenied
    case speechRestricted
    case micDenied
    /// No recognizer for this language, or it needs the network and there's no on-device model.
    case unavailable
    /// The person just declined the permission prompt; nothing to explain.
    case declined
    case failed(String)

    public var message: String {
        switch self {
        case .speechDenied: L("Speech recognition is off for Pincer. Turn it on in Settings to dictate.")
        case .speechRestricted: L("Speech recognition is restricted on this device.")
        case .micDenied: L("Microphone access is off for Pincer. Turn it on in Settings to dictate.")
        case .unavailable: L("Dictation isn't available for your language right now.")
        case .declined: ""
        case let .failed(reason): reason
        }
    }

    /// Whether the system Settings can fix it.
    public var canOpenSettings: Bool { self == .speechDenied || self == .micDenied }
}

@MainActor
public protocol DictationEngine: AnyObject {
    /// Asks for speech and microphone permission; nil when both are granted.
    func authorize() async -> DictationIssue?
    /// Starts listening. `onPartial` gets the whole transcript so far each time it changes.
    func start(onPartial: @escaping @MainActor (String, _ isFinal: Bool) -> Void,
               onError: @escaping @MainActor (DictationIssue) -> Void) throws
    /// Stops listening; a final result may still arrive.
    func stop()
    /// Stops and discards anything pending.
    func cancel()
    var isAvailable: Bool { get }
}

@MainActor @Observable
public final class DictationModel {
    public private(set) var phase: DictationPhase = .idle
    public var issue: DictationIssue?

    public var isActive: Bool { self.phase != .idle }
    public var isListening: Bool { self.phase == .listening }
    public var isAvailable: Bool { self.engine.isAvailable }

    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let finishGrace: Duration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var splice = DictationSplice(draft: "", insertionOffset: nil)
    @ObservationIgnored private var lastApplied = ""
    @ObservationIgnored private var apply: (@MainActor (String) -> Void)?
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    public init(engine: DictationEngine, finishGrace: Duration = .seconds(1.5)) {
        self.engine = engine
        self.finishGrace = finishGrace
    }

    /// Starts dictating into `draft` at `caret` (nil = the end), or finishes if already dictating.
    /// `apply` receives the whole new draft each time the transcript changes.
    public func toggle(draft: String, caret: Int?, apply: @escaping @MainActor (String) -> Void) {
        guard self.phase == .idle else { return self.finish() }
        self.issue = nil
        self.generation += 1
        let generation = self.generation
        self.splice = DictationSplice(draft: draft, insertionOffset: caret)
        self.lastApplied = draft
        self.apply = apply
        let controller = ReadAloudController.shared
        controller.stop()
        controller.activeDictation = self
        self.phase = .requestingPermission
        Task { [weak self] in
            guard let self else { return }
            let problem = await self.engine.authorize()
            guard generation == self.generation else { return }
            if let problem { return self.fail(problem) }
            self.phase = .starting
            do {
                try self.engine.start(
                    onPartial: { [weak self] text, isFinal in self?.received(text, isFinal: isFinal, generation: generation) },
                    onError: { [weak self] issue in self?.received(error: issue, generation: generation) })
                if self.phase == .starting { self.phase = .listening }
            } catch {
                self.fail(error as? DictationIssue ?? .failed(error.localizedDescription))
            }
        }
    }

    /// Stops listening and keeps the text; the last words may still land for a moment.
    public func finish() {
        switch self.phase {
        case .idle, .finishing: return
        case .requestingPermission, .starting:
            self.cancel()
        case .listening:
            self.phase = .finishing
            self.engine.stop()
            let generation = self.generation
            self.graceTask = Task { [weak self, grace = self.finishGrace] in
                try? await Task.sleep(for: grace)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.end()
            }
        }
    }

    /// Stops right away; nothing more is inserted. The text so far stays.
    public func cancel() {
        guard self.phase != .idle else { return }
        self.engine.cancel()
        self.end()
    }

    /// The draft changed by something other than dictation (the user typed, or it was sent or cleared):
    /// stop listening and keep whatever is there.
    public func draftChangedExternally(_ text: String) {
        guard self.isActive, text != self.lastApplied else { return }
        self.cancel()
    }

    private func received(_ text: String, isFinal: Bool, generation: Int) {
        guard generation == self.generation, self.phase == .listening || self.phase == .finishing || self.phase == .starting else { return }
        let next = self.splice.applying(text)
        if next != self.lastApplied {
            self.lastApplied = next
            self.apply?(next)
        }
        if self.phase == .starting { self.phase = .listening }
        if isFinal {
            self.engine.cancel()
            self.end()
        }
    }

    private func received(error: DictationIssue, generation: Int) {
        guard generation == self.generation, self.isActive else { return }
        // Errors while wrapping up (no speech heard, the task ending) aren't worth showing.
        if self.phase == .finishing { return self.end() }
        self.fail(error)
    }

    private func fail(_ issue: DictationIssue) {
        self.engine.cancel()
        self.end()
        if issue != .declined { self.issue = issue }
    }

    private func end() {
        self.generation += 1
        self.graceTask?.cancel()
        self.graceTask = nil
        self.apply = nil
        self.phase = .idle
    }
}
