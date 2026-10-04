#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class HeldSendDictationEngine: DictationEngine {
    var isAvailable = true
    var stopped = false
    var partial: (@MainActor (String, Bool) -> Void)?
    func authorize() async -> DictationIssue? { nil }
    func start(onPartial: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (DictationIssue) -> Void) throws { self.partial = onPartial }
    func stop() { self.stopped = true }
    func cancel() { self.partial = nil }
    func finish() { self.partial?("dictation ownership marker", true) }
}

@MainActor
private func exerciseActualDictationSend(cancelEdit: Bool, restartBeforeTask: Bool = false) async throws {
    let scratch = ScratchDefaults()
    defer { scratch.remove() }
    let app = AppModel(defaults: scratch.defaults)
    let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    func wait(_ phase: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate() {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "actual dictation composer did not settle: \(phase)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    gateway.start()
    gateway.reconnectIfNeeded()
    try await wait("Demo connection") { gateway.state.isConnected }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    let user = try #require(chat.items.last { $0.role == .user && !$0.isPending })
    chat.draft = ComposerDraft(text: "Unsent normal draft")
    try #require(chat.beginEdit(user.id))
    let engine = HeldSendDictationEngine()
    let model = DictationModel(engine: engine)
    defer { model.cancel() }
    let host = UIHostingController(rootView: AnyView(Composer(chat: chat, placeholder: "Message", dictationModel: model)
        .environment(app).environment(gateway).defaultAppStorage(scratch.defaults)))
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        window = UIWindow(windowScene: scene)
    } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 800)) }
    window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.loadViewIfNeeded()
    func field(_ view: UIView) -> ComposerUITextView? {
        if let result = view as? ComposerUITextView { return result }
        return view.subviews.lazy.compactMap(field).first
    }
    var native: ComposerUITextView?
    try await wait("initial native field") {
        host.view.layoutIfNeeded()
        native = field(host.view)
        return native?.text == chat.draft.text && native?.canSubmit == true
    }
    let textView = try #require(native)
    try #require(textView.becomeFirstResponder())
    model.toggle(draft: chat.draft.text, caret: nil) { [weak chat] text in chat?.draft.text = text }
    try await wait("dictation listening") { model.phase == .listening }
    let command = try #require(textView.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
    let action = try #require(command.action)
    _ = textView.perform(action, with: command)
    if restartBeforeTask {
        let draft = chat.draft
        let rows = chat.items
        model.cancel()
        model.toggle(draft: chat.draft.text, caret: nil) { [weak chat] text in chat?.draft.text = text }
        try await wait("new session after queued Return") {
            host.view.layoutIfNeeded()
            return textView.canSubmit && (model.isListening || model.phase == .idle)
        }
        #expect(model.isListening, "the queued old Return must not cancel the restarted session")
        #expect(!engine.stopped && chat.draft == draft && chat.items == rows,
                "the stale submit never touches the new engine or sends its draft")
        return
    }
    try await wait("Return stopped dictation") { engine.stopped && model.phase == .finishing }
    try await wait("native submit disabled") {
        host.view.layoutIfNeeded()
        return textView.canSubmit == false
    }
    let before = chat.items
    let beforeOutbox = gateway.outbox.entries.filter { $0.sessionKey == chat.sessionKey }
    if cancelEdit {
        chat.cancelEdit()
        try #require(chat.draft.text == "Unsent normal draft")
        // The actual Composer draft lifecycle receives cancelEdit's restored draft.
    } else {
        engine.finish()
    }
    try await wait("dictation final or lifecycle cancellation") { !model.isActive }
    try await wait("submit continuation terminal state") {
        host.view.layoutIfNeeded()
        return (textView.canSubmit || chat.draft.text.isEmpty) && !chat.isSendingEdit
    }
    if cancelEdit {
        #expect(chat.draft.text == "Unsent normal draft", "cancelled edit must not send the restored normal draft")
        #expect(chat.items == before && gateway.outbox.entries.filter { $0.sessionKey == chat.sessionKey } == beforeOutbox,
                "actual Return continuation cannot send after edit cancellation")
    } else {
        try await wait("authoritative edited marker") {
            chat.editTarget == nil && chat.items.contains {
                $0.role == .user && !$0.isPending && $0.plainText.contains("dictation ownership marker")
            }
        }
        #expect(chat.draft.text == "Unsent normal draft", "unchanged editing send restores its saved draft")
        #expect(chat.errorMessage == nil)
    }
}

extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func actualDictationReturnCannotSendAfterEditCancellation() async throws {
        try await exerciseActualDictationSend(cancelEdit: true)
    }
    @Test(.timeLimit(.minutes(2))) func queuedActualDictationReturnCannotStopRestartedSession() async throws {
        try await exerciseActualDictationSend(cancelEdit: false, restartBeforeTask: true)
    }
    @Test(.timeLimit(.minutes(2))) func actualDictationReturnStillSendsUnchangedEdit() async throws {
        try await exerciseActualDictationSend(cancelEdit: false)
    }
}
#endif
