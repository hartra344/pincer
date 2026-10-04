#if os(iOS) && DEBUG
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor private final class EditTaskCapture {
    var task: Task<Void, Never>?
    var sessionKey: String?
    var count = 0
}

@MainActor private func exerciseQueuedActualEdit(cancelBeforeTask: Bool) async throws {
    let scratch = ScratchDefaults()
    defer { scratch.remove() }
    let app = AppModel(defaults: scratch.defaults)
    let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    func wait(_ phase: String, _ predicate: () -> Bool) async throws {
        do {
            while !predicate() {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            print("Queued edit phase=\(phase) connected=\(gateway.state.isConnected) bootstrapped=\(gateway.bootstrapped)")
            throw error
        }
    }
    gateway.start(); gateway.reconnectIfNeeded()
    try await wait("Demo connection") { gateway.state.isConnected && gateway.bootstrapped }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    let user = try #require(chat.items.last { $0.role == .user && !$0.isPending })
    chat.draft = ComposerDraft(text: "Saved normal draft")
    let saved = chat.draft
    try #require(chat.beginEdit(user.id))
    let marker = "Actual queued edit marker " + UUID().uuidString
    chat.draft.text = marker
    let capture = EditTaskCapture()
    defer { capture.task?.cancel(); capture.task = nil }
    let host = UIHostingController(rootView: AnyView(Composer(chat: chat, placeholder: "Message")
        .environment(app).environment(gateway).defaultAppStorage(scratch.defaults)
        .environment(\.composerEditTaskObserver, { key, task in
            capture.sessionKey = key; capture.task = task; capture.count += 1
        })))
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        window = UIWindow(windowScene: scene)
    } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 800)) }
    window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.loadViewIfNeeded()
    func field(_ view: UIView) -> ComposerUITextView? {
        if let result = view as? ComposerUITextView { return result }
        return view.subviews.lazy.compactMap(field).first
    }
    var native: ComposerUITextView?
    try await wait("actual native Return readiness") {
        host.view.layoutIfNeeded(); native = field(host.view)
        return native?.text == marker && native?.canSubmit == true
    }
    let nativeField = try #require(native)
    try #require(nativeField.becomeFirstResponder())
    let command = try #require(nativeField.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
    let action = try #require(command.action)
    let before = chat.items
    let outbox = gateway.outbox.entries.filter { $0.sessionKey == chat.sessionKey }
    _ = nativeField.perform(action, with: command)
    // No suspension: the MainActor edit-send Task cannot start before this Cancel.
    let actualTask = try #require(capture.task)
    try #require(capture.count == 1 && capture.sessionKey == chat.sessionKey)
    if cancelBeforeTask {
        chat.cancelEdit()
        try #require(chat.draft.ownerID == saved.ownerID && chat.draft == saved)
    }
    await withTaskCancellationHandler {
        await actualTask.value
    } onCancel: { actualTask.cancel() }
    capture.task = nil
    if cancelBeforeTask {
        #expect(chat.draft.ownerID == saved.ownerID && chat.draft == saved,
                "A queued edit must not send or clear the restored normal draft")
        #expect(chat.items == before && gateway.outbox.entries.filter { $0.sessionKey == chat.sessionKey } == outbox,
                "Actual queued Return must not fall back to sending its obsolete edited text")
    } else {
        try await wait("authoritative accepted edit") {
            chat.editTarget == nil && chat.items.contains { $0.role == .user && !$0.isPending && $0.plainText == marker }
        }
        #expect(chat.draft.ownerID == saved.ownerID && chat.draft == saved)
        #expect(chat.errorMessage == nil && !chat.isSendingEdit)
    }
}

extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func queuedActualEditReturnCannotSendAfterImmediateCancel() async throws {
        try await exerciseQueuedActualEdit(cancelBeforeTask: true)
    }
    @Test(.timeLimit(.minutes(2))) func queuedActualEditReturnStillAcceptsUnchangedSelection() async throws {
        try await exerciseQueuedActualEdit(cancelBeforeTask: false)
    }
}
#endif
