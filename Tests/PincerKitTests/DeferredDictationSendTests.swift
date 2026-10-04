import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class DeferredSendEngine: DictationEngine {
    var isAvailable = true
    var stops = 0
    var synchronousFinal = false
    var partial: (@MainActor (String, Bool) -> Void)?
    func authorize() async -> DictationIssue? { nil }
    func start(onPartial: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (DictationIssue) -> Void) throws { self.partial = onPartial }
    func stop() { self.stops += 1; if self.synchronousFinal { self.partial?("synchronous final", true) } }
    func cancel() {}
}

@MainActor
@Suite("Deferred dictation send ownership")
struct DeferredDictationSendTests {
    @Test(arguments: [false, true]) func explicitCancellationOrDepartureRejectsPendingSend(departure: Bool) async {
        let engine = DeferredSendEngine()
        let model = DictationModel(engine: engine)
        defer { model.cancel() }
        model.toggle(draft: "draft", caret: nil) { _ in }
        #expect(await eventually { model.isListening })
        let waiter = Task { await model.finishForSend(timeout: .seconds(5)) }
        #expect(await eventually { engine.stops == 1 })
        if departure {
            model.invalidateDeferredSend()
            engine.partial?("last words", true)
        } else { model.cancel() }
        #expect(await waiter.value == false)
    }
    @Test(arguments: [false, true]) func finalAndTimeoutKeepRecognizedWords(timeout: Bool) async {
        let engine = DeferredSendEngine()
        let model = DictationModel(engine: engine)
        var draft = "draft"
        defer { model.cancel() }
        model.toggle(draft: draft, caret: nil) { draft = $0 }
        #expect(await eventually { model.isListening })
        engine.partial?("recognized", false)
        let waiter = Task { await model.finishForSend(timeout: timeout ? .milliseconds(20) : .seconds(5)) }
        #expect(await eventually { engine.stops == 1 })
        if !timeout { engine.partial?("recognized", true) }
        #expect(await waiter.value)
        #expect(draft.contains("recognized"))
    }
    @Test(.timeLimit(.minutes(1))) func synchronousFinalCompletesWithoutRegisteringAnIdleWaiter() async {
        let engine = DeferredSendEngine()
        engine.synchronousFinal = true
        let model = DictationModel(engine: engine)
        var draft = "draft"
        defer { model.cancel() }
        model.toggle(draft: draft, caret: nil) { draft = $0 }
        #expect(await eventually { model.isListening })
        var completed = false
        let waiter = Task {
            let accepted = await model.finishForSend(timeout: .seconds(30))
            completed = true
            return accepted
        }
        #expect(await eventually { completed }, "synchronous final must finish without waiting for the timeout")
        if !completed { model.cancel() }
        #expect(await waiter.value)
        #expect(model.phase == .idle && draft.contains("synchronous final"))
        #expect(model.endedForSend, "a synchronous final remains a Send completion, not a Stop announcement")
    }
    @Test(.timeLimit(.minutes(1))) func newSessionInvalidatesFinalizedOldWaiterBeforeItResumes() async {
        let engine = DeferredSendEngine()
        let model = DictationModel(engine: engine)
        defer { model.cancel() }
        model.toggle(draft: "draft", caret: nil) { _ in }
        #expect(await eventually { model.isListening })
        let waiter = Task { await model.finishForSend(timeout: .seconds(5)) }
        #expect(await eventually { engine.stops == 1 })
        engine.partial?("final", true)
        // No suspension between the final and a new session: the old waiter has not resumed.
        model.toggle(draft: "new draft", caret: nil) { _ in }
        #expect(await waiter.value == false)
        #expect(await eventually { model.isListening })
        #expect(engine.stops == 1, "old send does not finish the new dictation")
    }
    @Test func actualChatOwnerRejectsCancelledEditAndReplacement() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = gateway.chat(for: "agent:main:ownership")
        let saved = ComposerDraft(text: "normal")
        chat.editTarget = MessageEditTarget(messageId: "edited", entryId: "entry", originalText: "edit", savedDraft: saved)
        chat.draft = ComposerDraft(text: "edit")
        let owner = chat.draft.ownerID
        #expect(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edited"))
        chat.cancelEdit()
        #expect(!chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edited"))
        #expect(chat.draft.ownerID == saved.ownerID)
        chat.draft = ComposerDraft(text: saved.text)
        #expect(!chat.ownsDeferredSend(draftOwnerID: saved.ownerID, editingMessageID: nil))
    }
}
