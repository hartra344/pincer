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

    func authorize() async -> DictationIssue? { authorizeResult }

    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        self.onPartial = onPartial
        self.onError = onError
    }

    func stop() { stops += 1 }
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
}
