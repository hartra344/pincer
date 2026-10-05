#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class NormalDraftResendGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor func runEditSendNormalDraftPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("normal draft resend Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual normal draft Demo bootstrap completes"); guard ready else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    guard let user = chat.items.first(where: { $0.role == .user && $0.isCommittedEntry }) else { check(false, "actual editable user exists"); return }
    chat.draft = ComposerDraft(text: "new normal draft")
    let owner = chat.draft.ownerID
    let selected = chat.beginEdit(user.id)
    check(selected, "actual user edit starts"); guard selected else { return }
    let gate = NormalDraftResendGate()
    await gateway.connection.setDemoResponseDelivery { method in if method == "chat.send" { await gate.hold() } }
    let sending = Task { await chat.sendEdit("actual resend boundary", attachments: []) }
    let entered = await waitFor("actual resend acknowledgement held", timeout: 25) { gate.entered }
    let restored = entered && chat.isSendingEdit && chat.editTarget == nil && chat.draft.ownerID == owner
    check(restored, "real rewind restored normal draft while resend still waits")
    guard restored else {
        sending.cancel(); gate.release(); _ = await sending.value
        await gateway.connection.setDemoResponseDelivery(nil); return
    }
    guard let token = chat.beginAttachmentPreparation(ownerID: owner) else {
        check(false, "normal draft admits preparation during resend acknowledgement")
        sending.cancel(); gate.release(); _ = await sending.value
        await gateway.connection.setDemoResponseDelivery(nil); return
    }
    let bytes = await Task.detached { Data([1, 2, 3]) }.value
    let attachment = OutgoingAttachment(fileName: "normal.txt", mimeType: "text/plain", data: bytes)
    chat.appendPreparedAttachment(attachment, ownerID: owner)
    chat.finishAttachmentPreparation(token)
    gate.release()
    let outcome = await sending.value
    await gateway.connection.setDemoResponseDelivery(nil)
    if case .sent = outcome { check(true, "actual connected Demo resend completes as sent") }
    else { check(false, "actual connected Demo resend completes as sent") }
    check(!chat.isSendingEdit && chat.draft.ownerID == owner && chat.draft.text == "new normal draft" && chat.draft.attachments == [attachment],
          "actual resend preserves the newly prepared normal draft")
}
#endif
