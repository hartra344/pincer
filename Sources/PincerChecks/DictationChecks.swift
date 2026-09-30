import Foundation
import PincerKit

@MainActor
private final class ScriptedDictationEngine: DictationEngine {
    var isAvailable = true
    var authorizeResult: DictationIssue?
    var onPartial: (@MainActor (String, Bool) -> Void)?
    var onError: (@MainActor (DictationIssue) -> Void)?
    var stops = 0
    var cancels = 0
    var finalAfterStop: (text: String, delay: Duration)?

    func authorize() async -> DictationIssue? { authorizeResult }

    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
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

/// Dictation splicing and `DictationModel` against a scripted engine.
@MainActor
func runDictationChecks() async {
    let splice = DictationSplice(draft: "Hello world", insertionOffset: 5)
    check(splice.applying("big") == "Hello big world" && splice.applying("big red") == "Hello big red world"
          && splice.applying("") == "Hello world", "splice replaces the previous partial in place")
    check(DictationSplice(draft: "Hi", insertionOffset: nil).applying("there") == "Hi there"
          && DictationSplice(draft: "Hello.", insertionOffset: 5).applying("world") == "Hello world."
          && DictationSplice(draft: "", insertionOffset: nil).applying("x") == "x", "splice spacing and punctuation")

    let engine = ScriptedDictationEngine()
    let model = DictationModel(engine: engine, finishGrace: .milliseconds(20))
    var draft = "Hello"
    model.toggle(draft: draft, caret: nil) { draft = $0 }
    let listening = await waitFor("dictation listening", timeout: 5) { model.isListening }
    check(listening, "dictation starts listening")
    engine.onPartial?("there", false)
    engine.onPartial?("there friend", false)
    check(draft == "Hello there friend", "partials replace each other (\(draft))")
    model.draftChangedExternally(draft)
    check(model.isListening, "its own writes aren't external edits")
    model.draftChangedExternally(draft + "!")
    check(!model.isActive && engine.cancels >= 1, "typing finishes dictation")
    engine.onPartial?("ghost", false)
    check(draft == "Hello there friend", "nothing lands after it ends")

    model.toggle(draft: "", caret: nil) { draft = $0 }
    _ = await waitFor("dictation listening again", timeout: 5) { model.isListening }
    engine.onPartial?("done", true)
    check(draft == "done" && model.phase == .idle, "a final result ends dictation")

    engine.authorizeResult = .speechDenied
    model.toggle(draft: "keep", caret: nil) { draft = $0 }
    _ = await waitFor("dictation denied", timeout: 5) { !model.isActive }
    check(model.issue == .speechDenied && model.issue?.canOpenSettings == true && draft == "done", "denied permission surfaces an issue")

    let sel = DictationSplice(draft: "Hello big world", selection: NSRange(location: 6, length: 3))
    check(sel.applying("small") == "Hello small world" && sel.caret(after: "small") == 11, "a selection is replaced and the caret follows the dictation")
    check(DictationSplice(draft: "a😀b", selection: NSRange(location: 2, length: 0)).applying("X") == "a X 😀b"
          && DictationSplice(draft: "Hi", selection: NSRange(location: 99, length: 5)).applying("x") == "Hi x", "selection snaps to characters and clamps")
    engine.authorizeResult = nil
    var caret = -1
    draft = "one three"
    model.toggle(draft: draft, selection: NSRange(location: 3, length: 0)) { text, offset in draft = text; caret = offset }
    _ = await waitFor("dictation listening at a caret", timeout: 5) { model.isListening }
    engine.onPartial?("two", false)
    check(draft == "one two three" && caret == 7, "dictation lands at the caret and reports it (\(draft), \(caret))")
    model.cancel()

    // Send while listening (#464): the final result that arrives just after stop() must land in the draft.
    let sendEngine = ScriptedDictationEngine()
    sendEngine.finalAfterStop = ("send the report", .milliseconds(50))
    let sendModel = DictationModel(engine: sendEngine)
    var sendDraft = ""
    sendModel.toggle(draft: sendDraft, selection: nil) { text, _ in sendDraft = text }
    _ = await waitFor("dictation listening before send", timeout: 5) { sendModel.isListening }
    sendEngine.onPartial?("send the", false)
    await sendModel.finishForSend()
    check(sendDraft == "send the report" && sendModel.phase == .idle, "Send waits for the final words (\(sendDraft))")

    let slowEngine = ScriptedDictationEngine()
    slowEngine.finalAfterStop = ("too slow", .milliseconds(300))
    let slowModel = DictationModel(engine: slowEngine)
    var slowDraft = ""
    slowModel.toggle(draft: slowDraft, selection: nil) { text, _ in slowDraft = text }
    _ = await waitFor("dictation listening before slow send", timeout: 5) { slowModel.isListening }
    slowEngine.onPartial?("partial", false)
    await slowModel.finishForSend(timeout: .milliseconds(30))
    try? await Task.sleep(for: .milliseconds(350))
    check(slowDraft == "partial" && !slowModel.isActive && slowEngine.cancels == 1, "Send gives up after the timeout and ignores a late final")

    await sendModel.finishForSend()
    check(!sendModel.isActive, "finishForSend while idle returns at once")
}
