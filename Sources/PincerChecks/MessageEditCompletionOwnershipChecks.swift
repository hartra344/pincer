#if DEBUG
import Foundation
@testable import PincerKit

@MainActor func runMessageEditCompletionOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var gateway: GatewayStore? = GatewayStore(profile: .demo(), defaults: defaults)
    let chat = gateway!.chat(for: "agent:main:edit-ownership-offline")
    chat.editTarget = MessageEditTarget(messageId: "user", entryId: "entry", originalText: "original", savedDraft: ComposerDraft(text: "normal"))
    chat.draft.text = "current edit"
    chat.errorMessage = "current feedback"
    let canceled = Task { await chat.sendEdit("must not admit", attachments: []) }
    canceled.cancel()
    _ = await canceled.value
    check(!chat.isSendingEdit && chat.draft.text == "current edit" && chat.errorMessage == "current feedback",
          "precanceled actual sendEdit leaves current draft and feedback untouched")
    gateway = nil // ChatStore holds its Gateway weakly; exercise the actual current failure path.
    let outcome = await chat.sendEdit("current edit", attachments: [])
    if case let .failed(message) = outcome {
        check(chat.errorMessage == message && chat.editTarget != nil && chat.draft.text == "current edit",
              "current disconnected edit failure retains its draft and publishes its own error")
    } else { check(false, "current disconnected edit must fail") }
}

@MainActor func runDemoMessageEditCompletionOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("edit ownership Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "actual Demo is connected before edit ownership checks")
    guard connected else { return }
    let source = gateway.chat(for: "agent:main:dashboard:garden")
    await source.load()
    guard let assistant = source.items.last(where: { $0.role == .assistant && $0.isCommittedEntry }) else {
        check(false, "actual Garden assistant is available"); return
    }
    for mode in ["cancel", "current", "ABA"] {
        let cancel = mode == "cancel"
        guard let key = await source.branch(from: assistant.id) else { check(false, "actual Demo fork succeeds"); return }
        let chat = gateway.chat(for: key)
        await chat.load()
        guard let user = chat.items.last(where: { $0.role == .user && $0.isCommittedEntry }) else {
            check(false, "forked user is available"); return
        }
        chat.draft.text = "normal draft"
        check(chat.beginEdit(user.id), "actual edit selection begins")
        var arrived = false
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
        func release() { released = true; let held = continuation; continuation = nil; held?.resume() }
        var admitted = false
        var admissionReleased = false
        var admissionContinuation: CheckedContinuation<Void, Never>?
        func releaseAdmission() {
            admissionReleased = true
            let held = admissionContinuation; admissionContinuation = nil; held?.resume()
        }
        if mode == "ABA" {
            chat.messageEditRewindAdmissionProbe = {
                admitted = true
                await withCheckedContinuation { held in
                    if admissionReleased || Task.isCancelled { held.resume() } else { admissionContinuation = held }
                }
            }
        }
        chat.messageEditRewindCompletionProbe = { success in
            check(success, "actual Demo rewind has already succeeded")
            arrived = true
            await withCheckedContinuation { held in
                if released || Task.isCancelled { held.resume() } else { continuation = held }
            }
        }
        defer {
            releaseAdmission(); release()
            chat.messageEditRewindAdmissionProbe = nil; chat.messageEditRewindCompletionProbe = nil
        }
        let task = Task { await chat.sendEdit("owned Demo resend", attachments: []) }
        defer { task.cancel(); releaseAdmission(); release() }
        if mode == "ABA" {
            let admissionReady = await waitFor("actual edit ownership admission", timeout: 20) { admitted }
            check(admissionReady, "real edit captures ownership before its rewind request")
            guard admissionReady else { return }
            chat.cancelEdit()
            check(chat.beginEdit(user.id), "same committed message can be reselected before real rewind")
            chat.draft.text = "fresh same-message draft"
            releaseAdmission()
        }
        let ready = await waitFor("actual rewind completion gate", timeout: 20) { arrived }
        check(ready, "real rewind completion reaches gate")
        guard ready else { return }
        if cancel { chat.cancelEdit(); chat.draft.text = "fresh normal draft" }
        if mode == "ABA" { chat.errorMessage = "current same-message feedback" }
        release()
        let outcome = await task.value
        check(!chat.isSendingEdit, "actual edit task completes and releases busy state")
        if cancel {
            check(chat.editTarget == nil && chat.draft.text == "fresh normal draft", "old completion preserves canceled replacement draft")
        } else if mode == "ABA" {
            check(chat.editTarget?.messageId == user.id && chat.draft.text == "fresh same-message draft"
                  && chat.errorMessage == "current same-message feedback",
                  "actual old rewind completion preserves same-message reselection and feedback")
        } else {
            if case .sent = outcome { check(true, "current edit sends") } else { check(false, "current edit sends") }
            check(chat.editTarget == nil && chat.draft.text == "normal draft", "current edit restores normal draft")
        }
        do {
            let response = try await gateway.connection.request("chat.history", ["sessionKey": .string(key)])
            guard let messages = response["messages"]?.array else { check(false, "actual history response has messages"); return }
            check(messages.filter { $0["role"]?.text == "user" }.count == (mode == "current" ? 2 : 1),
                  "actual backend retains applied rewind, and only the current edit resends")
        } catch { check(false, "actual history read succeeds") }
    }
}
#endif
