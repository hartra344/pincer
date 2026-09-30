import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class FakeEngine: DictationEngine {
    var isAvailable = true
    var authorizeResult: DictationIssue?
    var authorizeHold = false
    var startError: Error?
    var starts = 0
    var stops = 0
    var cancels = 0
    var onPartial: (@MainActor (String, Bool) -> Void)?
    var onError: (@MainActor (DictationIssue) -> Void)?
    /// Like the real recognizer: after stop() (endAudio) the final transcript arrives a moment later.
    var finalAfterStop: (text: String, delay: Duration)?
    private var waiting: CheckedContinuation<Void, Never>?

    func authorize() async -> DictationIssue? {
        if authorizeHold { await withCheckedContinuation { waiting = $0 } }
        return authorizeResult
    }

    func releaseAuthorize() {
        waiting?.resume()
        waiting = nil
    }

    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        starts += 1
        if let startError { throw startError }
        self.onPartial = onPartial
        self.onError = onError
    }

    func stop() {
        stops += 1
        guard let (text, delay) = finalAfterStop else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.onPartial?(text, true)
        }
    }

    func cancel() { cancels += 1 }
}

@MainActor
private final class SilentPlayer: ReadAloudClipPlaying {
    func play(_ clip: TTSClip) async -> Bool { true }
    func stop() {}
}

@MainActor
private final class SilentSpeaker: ReadAloudLocalSpeaking {
    var spoken: [String] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { spoken.append(text); return true }
    func stop() {}
}

@MainActor
private final class Draft {
    var text: String
    var history: [String] = []
    init(_ text: String) { self.text = text }
    func set(_ value: String) { text = value; history.append(value) }
}

@MainActor
private func settle(_ model: DictationModel, until phase: DictationPhase) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while model.phase != phase {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Dictation model", .serialized)
@MainActor
struct DictationModelTests {
    private func start(_ model: DictationModel, _ draft: Draft, caret: Int? = nil) async -> Bool {
        model.toggle(draft: draft.text, caret: caret) { draft.set($0) }
        return await settle(model, until: .listening)
    }

    @Test func partialsReplaceEachOtherAndFinalEnds() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("Hello")
        #expect(model.phase == .idle && !model.isActive && model.isAvailable)
        model.toggle(draft: draft.text, caret: nil) { draft.set($0) }
        #expect(model.phase == .requestingPermission && model.isActive)
        #expect(await settle(model, until: .listening))
        #expect(engine.starts == 1 && model.isListening)
        engine.onPartial?("hi", false)
        engine.onPartial?("hi there", false)
        #expect(draft.text == "Hello hi there")
        engine.onPartial?("hi there friend", true)
        #expect(draft.text == "Hello hi there friend")
        #expect(model.phase == .idle && model.issue == nil)
        #expect(draft.history == ["Hello hi", "Hello hi there", "Hello hi there friend"])
    }

    @Test func insertsAtCaret() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("Hello world")
        #expect(await start(model, draft, caret: 5))
        engine.onPartial?("big", false)
        #expect(draft.text == "Hello big world")
        model.cancel()
    }

    @Test func identicalPartialsApplyOnce() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("same", false)
        engine.onPartial?("same", false)
        #expect(draft.history == ["same"])
        model.cancel()
    }

    @Test(arguments: [DictationIssue.speechDenied, .speechRestricted, .micDenied])
    func permissionProblemsSurface(issue: DictationIssue) async {
        let engine = FakeEngine()
        engine.authorizeResult = issue
        let model = DictationModel(engine: engine)
        let draft = Draft("keep")
        model.toggle(draft: draft.text, caret: nil) { draft.set($0) }
        #expect(await settle(model, until: .idle))
        #expect(model.issue == issue && engine.starts == 0 && draft.text == "keep" && draft.history.isEmpty)
        #expect(!issue.message.isEmpty)
        #expect(issue.canOpenSettings == (issue != .speechRestricted))
    }

    @Test func issueFlags() {
        #expect(!DictationIssue.unavailable.canOpenSettings && !DictationIssue.failed("x").canOpenSettings)
        #expect(DictationIssue.failed("boom").message == "boom")
        #expect(!DictationIssue.unavailable.message.isEmpty)
    }

    @Test func startThrowingIssueOrError() async {
        let engine = FakeEngine()
        engine.startError = DictationIssue.unavailable
        let model = DictationModel(engine: engine)
        let draft = Draft("x")
        model.toggle(draft: "x", caret: nil) { draft.set($0) }
        #expect(await settle(model, until: .idle))
        #expect(model.issue == .unavailable && engine.cancels >= 1)

        struct Boom: LocalizedError { var errorDescription: String? { "engine broke" } }
        engine.startError = Boom()
        model.toggle(draft: "x", caret: nil) { draft.set($0) }
        #expect(await settle(model, until: .idle))
        #expect(model.issue == .failed("engine broke"))
    }

    @Test func engineErrorWhileListeningKeepsTextAndReportsIssue() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("A")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        engine.onError?(.failed("network"))
        #expect(model.phase == .idle && model.issue == .failed("network") && draft.text == "A one")
        engine.onPartial?("late", false)
        #expect(draft.text == "A one", "nothing lands after the error")
    }

    @Test func newToggleClearsPreviousIssue() async {
        let engine = FakeEngine()
        engine.authorizeResult = .micDenied
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(await settle(model, until: .idle) && model.issue == .micDenied)
        engine.authorizeResult = nil
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(model.issue == nil)
        #expect(await settle(model, until: .listening))
        model.cancel()
    }

    @Test func toggleWhileListeningFinishesAndAcceptsLateFinal() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine, finishGrace: .seconds(5))
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("hello", false)
        model.toggle(draft: draft.text, caret: nil) { draft.set($0) }
        #expect(model.phase == .finishing && engine.stops == 1 && model.isActive)
        engine.onPartial?("hello world", true)
        #expect(draft.text == "hello world" && model.phase == .idle)
    }

    @Test func finishTimesOutAfterGrace() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine, finishGrace: .milliseconds(30))
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("text", false)
        model.finish()
        #expect(model.phase == .finishing)
        #expect(await settle(model, until: .idle))
        engine.onPartial?("too late", false)
        #expect(draft.text == "text")
    }

    @Test func finishTwiceAndIdleAreNoOps() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine, finishGrace: .seconds(5))
        model.finish()
        model.cancel()
        #expect(engine.stops == 0 && engine.cancels == 0)
        #expect(await start(model, Draft("")))
        model.finish()
        model.finish()
        #expect(engine.stops == 1)
        model.cancel()
        #expect(model.phase == .idle)
    }

    @Test func cancelStopsAndIgnoresLaterPartials() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("A")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        model.cancel()
        #expect(model.phase == .idle && engine.cancels == 1)
        engine.onPartial?("two", false)
        #expect(draft.text == "A one")
    }

    @Test func cancelDuringPermissionPromptIgnoresLateGrant() async {
        let engine = FakeEngine()
        engine.authorizeHold = true
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(model.phase == .requestingPermission)
        model.cancel()
        #expect(model.phase == .idle)
        engine.releaseAuthorize()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.starts == 0 && model.phase == .idle)
    }

    @Test func finishDuringPermissionPromptCancels() async {
        let engine = FakeEngine()
        engine.authorizeHold = true
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(model.phase == .idle)
        engine.releaseAuthorize()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.starts == 0)
    }

    @Test func staleGenerationCallbacksAreIgnored() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let first = Draft("")
        #expect(await start(model, first))
        let stalePartial = engine.onPartial
        let staleError = engine.onError
        model.cancel()
        let second = Draft("B")
        #expect(await start(model, second))
        stalePartial?("ghost", false)
        staleError?(.failed("ghost"))
        #expect(first.history.isEmpty && second.history.isEmpty && model.issue == nil && model.isListening)
        engine.onPartial?("real", false)
        #expect(second.text == "B real")
        model.cancel()
    }

    @Test func externalEditFinishesAndKeepsText() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("A")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        model.draftChangedExternally("A one")
        #expect(model.isListening, "our own write isn't an external edit")
        model.draftChangedExternally("A one!")
        #expect(model.phase == .idle && engine.cancels == 1)
        engine.onPartial?("two", false)
        #expect(draft.text == "A one")
    }

    @Test func externalEditWhenIdleIsIgnored() {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        model.draftChangedExternally("anything")
        #expect(model.phase == .idle && engine.cancels == 0)
    }

    @Test func draftClearedBySendStopsDictation() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("send me", false)
        model.draftChangedExternally("")
        #expect(model.phase == .idle)
    }

    @Test func unavailableEngineIsReported() {
        let engine = FakeEngine()
        engine.isAvailable = false
        #expect(!DictationModel(engine: engine).isAvailable)
    }

    @Test func engineErrorWhileFinishingEndsQuietly() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine, finishGrace: .seconds(5))
        let draft = Draft("A")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        model.finish()
        #expect(model.phase == .finishing)
        engine.onError?(.failed("no speech detected"))
        #expect(model.phase == .idle && model.issue == nil && draft.text == "A one")
    }

    @Test func decliningThePromptSetsNoIssue() async {
        let engine = FakeEngine()
        engine.authorizeResult = .declined
        let model = DictationModel(engine: engine)
        let draft = Draft("keep")
        model.toggle(draft: draft.text, caret: nil) { draft.set($0) }
        #expect(await settle(model, until: .idle))
        #expect(model.issue == nil && engine.starts == 0 && draft.history.isEmpty)
        #expect(!DictationIssue.declined.canOpenSettings)
    }

    @Test func decliningDoesNotClearAnEarlierIssueBeforeNextToggle() async {
        let engine = FakeEngine()
        engine.authorizeResult = .micDenied
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(await settle(model, until: .idle) && model.issue == .micDenied)
        engine.authorizeResult = .declined
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(await settle(model, until: .idle))
        #expect(model.issue == nil, "toggle cleared the old issue and declined adds none")
    }

    @Test func dictationRegistersWithReadAloudWhileActive() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        #expect(await start(model, Draft("")))
        #expect(ReadAloudController.shared.isDictating)
        model.cancel()
        #expect(!ReadAloudController.shared.isDictating)
    }

    @Test func startingReadAloudFinishesDictationFirst() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine, finishGrace: .seconds(5))
        let draft = Draft("A")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        let speaker = SilentSpeaker()
        let controller = ReadAloudController(clipPlayer: SilentPlayer(), localSpeaker: speaker,
                                             defaults: UserDefaults(suiteName: "pincer.tests.dictation.\(UUID().uuidString)")!)
        controller.activeDictation = model
        #expect(controller.isDictating)
        controller.start(messageId: "m1", text: "Read this.", gateway: nil)
        #expect(model.phase == .finishing && engine.stops == 1 && draft.text == "A one")
        model.cancel()
    }

    // MARK: - #464: words spoken just before Send

    // Old flow: Composer called finish() (engine.stop → endAudio), then immediately sent the stale partial and
    // cleared the draft. The cleared draft reached draftChangedExternally("") → cancel() → engine.cancel(), which
    // killed the recognition task, so the final "send the report" never landed and the message went out truncated.
    // finishForSend() must instead wait for the final result before Composer reads the draft.
    @Test func finishForSendWaitsForTheFinalResult() async {
        let engine = FakeEngine()
        engine.finalAfterStop = ("send the report", .milliseconds(50))
        let model = DictationModel(engine: engine)
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("send the", false)
        #expect(draft.text == "send the")
        await model.finishForSend()
        #expect(draft.text == "send the report")
        #expect(model.phase == .idle && !model.isActive && model.issue == nil)
        #expect(engine.stops == 1)
        let cancels = engine.cancels
        model.draftChangedExternally("")
        #expect(engine.cancels == cancels, "no-op once idle")
    }

    @Test func finishForSendTimesOutAndIgnoresALateFinal() async {
        let engine = FakeEngine()
        engine.finalAfterStop = ("send the report", .milliseconds(300))
        let model = DictationModel(engine: engine)
        let draft = Draft("Note:")
        #expect(await start(model, draft))
        engine.onPartial?("send the", false)
        await model.finishForSend(timeout: .milliseconds(30))
        #expect(model.phase == .idle && !model.isActive && model.issue == nil)
        #expect(draft.text == "Note: send the" && engine.cancels == 1)
        draft.set("")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(draft.text == "" && draft.history.last == "", "late final is ignored and doesn't touch the draft")
    }

    @Test func finishForSendAppliesPartialsThatArriveWhileWaiting() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("one", false)
        let waiter = Task { @MainActor in await model.finishForSend(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .finishing)
        engine.onPartial?("one two", false)
        engine.onPartial?("one two three", true)
        await waiter.value
        #expect(draft.text == "one two three" && model.phase == .idle)
    }

    @Test func finishForSendEndsQuietlyOnEngineError() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("hello", false)
        let waiter = Task { @MainActor in await model.finishForSend(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        engine.onError?(.failed("no speech detected"))
        await waiter.value
        #expect(model.phase == .idle && model.issue == nil && draft.text == "hello")
    }

    @Test func finishForSendAfterStopWasTappedSharesTheWait() async {
        let engine = FakeEngine()
        engine.finalAfterStop = ("hello world", .milliseconds(50))
        let model = DictationModel(engine: engine, finishGrace: .seconds(5))
        let draft = Draft("")
        #expect(await start(model, draft))
        engine.onPartial?("hello", false)
        model.finish()
        #expect(model.phase == .finishing)
        await model.finishForSend()
        #expect(draft.text == "hello world" && model.phase == .idle && engine.stops == 1)
    }

    @Test func finishForSendWhileIdleReturnsImmediately() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        let started = ContinuousClock.now
        await model.finishForSend(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(engine.stops == 0 && engine.cancels == 0 && model.phase == .idle)
    }

    @Test func finishForSendDuringPermissionPromptCancelsImmediately() async {
        let engine = FakeEngine()
        engine.authorizeHold = true
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        #expect(model.phase == .requestingPermission)
        let started = ContinuousClock.now
        await model.finishForSend(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(model.phase == .idle && !model.isActive)
        engine.releaseAuthorize()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.starts == 0 && model.phase == .idle, "a late grant doesn't start listening")
    }

    // MARK: - #461: selection and caret delivery

    @Test func toggleWithSelectionDeliversCaretOffsets() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        var draft = "Hello world"
        var carets: [Int] = []
        model.toggle(draft: draft, selection: NSRange(location: 5, length: 0)) { text, offset in draft = text; carets.append(offset) }
        #expect(await settle(model, until: .listening))
        engine.onPartial?("big", false)
        engine.onPartial?("big red", false)
        #expect(draft == "Hello big red world")
        #expect(carets == [9, 13])
        model.cancel()
    }

    @Test func toggleReplacesTheSelectionAndReportsTheCaret() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        var draft = "one 😀 three"
        var caret = -1
        model.toggle(draft: draft, selection: NSRange(location: 4, length: 2)) { text, offset in draft = text; caret = offset }
        #expect(await settle(model, until: .listening))
        engine.onPartial?("two", true)
        #expect(draft == "one two three" && caret == 7 && model.phase == .idle)
    }

    @Test func toggleWithNilSelectionDictatesAtTheEnd() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        var draft = "Hi"
        var caret = -1
        model.toggle(draft: draft, selection: nil) { text, offset in draft = text; caret = offset }
        #expect(await settle(model, until: .listening))
        engine.onPartial?("there", false)
        #expect(draft == "Hi there" && caret == 8)
        model.cancel()
    }

    // MARK: - Selection stays until words arrive; endedForSend

    @Test(arguments: [DictationIssue.speechDenied, .micDenied, .declined])
    func deniedStartLeavesASelectedDraftUntouched(issue: DictationIssue) async {
        let engine = FakeEngine()
        engine.authorizeResult = issue
        let model = DictationModel(engine: engine)
        var writes: [String] = []
        model.toggle(draft: "Hello big world", selection: NSRange(location: 6, length: 3)) { text, _ in writes.append(text) }
        #expect(await settle(model, until: .idle))
        #expect(writes.isEmpty && engine.starts == 0)
    }

    @Test func failedStartLeavesASelectedDraftUntouched() async {
        let engine = FakeEngine()
        engine.startError = DictationIssue.onDeviceUnavailable(language: "German")
        let model = DictationModel(engine: engine)
        var writes: [String] = []
        model.toggle(draft: "Hello big world", selection: NSRange(location: 6, length: 3)) { text, _ in writes.append(text) }
        #expect(await settle(model, until: .idle))
        #expect(writes.isEmpty && model.issue == .onDeviceUnavailable(language: "German"))
    }

    @Test func cancelBeforeAnyWordsLeavesASelectedDraftUntouched() async {
        let engine = FakeEngine()
        let model = DictationModel(engine: engine)
        var writes: [String] = []
        model.toggle(draft: "Hello big world", selection: NSRange(location: 6, length: 3)) { text, _ in writes.append(text) }
        #expect(await settle(model, until: .listening))
        engine.onPartial?("", false)
        engine.onPartial?("  ", false)
        #expect(writes.allSatisfy { $0 == "Hello big world" }, "an empty transcript never deletes the selection")
        model.cancel()
        #expect(writes.allSatisfy { $0 == "Hello big world" })
    }

    @Test func endedForSendIsSetOnlyByFinishForSend() async {
        let engine = FakeEngine()
        engine.finalAfterStop = ("hi there", .milliseconds(20))
        let model = DictationModel(engine: engine)
        #expect(!model.endedForSend)
        #expect(await start(model, Draft("")))
        model.finish()
        #expect(await settle(model, until: .idle))
        #expect(!model.endedForSend, "plain Stop isn't a send")

        #expect(await start(model, Draft("")))
        await model.finishForSend()
        #expect(model.endedForSend && model.phase == .idle)

        model.toggle(draft: "", caret: nil) { _ in }
        #expect(!model.endedForSend, "a new session resets it")
        model.cancel()
    }

    @Test func endedForSendAlsoSetWhenSendCancelsAPendingStart() async {
        let engine = FakeEngine()
        engine.authorizeHold = true
        let model = DictationModel(engine: engine)
        model.toggle(draft: "", caret: nil) { _ in }
        await model.finishForSend()
        #expect(model.endedForSend && model.phase == .idle)
        engine.releaseAuthorize()
    }
}
