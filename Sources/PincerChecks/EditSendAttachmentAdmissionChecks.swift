#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class EditAttachmentRewindGate {
    var entered: Bool?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold(_ success: Bool) async {
        entered = success
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

/// Kit admission coverage; the UI test separately exercises the shipped ingestion factory/codec.
@MainActor private func checkEditAttachmentAdmission() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("edit attachment Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo bootstrap completed"); guard ready else { return }
    let source = gateway.chat(for: "agent:main:dashboard:garden")
    await source.load()
    guard let assistant = source.items.last(where: { $0.role == .assistant && $0.isCommittedEntry }),
          let key = await source.branch(from: assistant.id) else { check(false, "actual seeded branch is created"); return }
    let chat = gateway.chat(for: key)
    await chat.load()
    guard let user = chat.items.last(where: {
        $0.role == .user && $0.isCommittedEntry && !$0.plainText.isEmpty && !$0.blocks.contains { if case .image = $0 { return true }; return false }
    }), let transcriptId = user.transcriptId else { check(false, "actual branch has an editable text-only user row"); return }
    do {
        let before = try await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": .number(200)])
        guard let original = before["messages"]?.array?.first(where: { $0["__openclaw"]?["id"]?.string == transcriptId }),
              original["role"]?.string == "user", let content = original["content"]?.array,
              content.contains(where: { $0["type"]?.string == "text" && $0["text"]?.string?.isEmpty == false }),
              !content.contains(where: { $0["type"]?.string == "image" }) else {
            check(false, "actual selected history row is nonempty text-only before rewind"); return
        }
        check(true, "actual selected history row is nonempty text-only before rewind")
    } catch { check(false, "actual original history prerequisite completes"); return }
    chat.draft = ComposerDraft(text: "normal saved draft")
    let normalOwner = chat.draft.ownerID
    guard let ordinary = chat.beginAttachmentPreparation(ownerID: normalOwner) else { check(false, "ordinary draft admits preparation"); return }
    chat.finishAttachmentPreparation(ordinary)
    check(chat.beginEdit(user.id), "actual committed user enters edit mode")
    guard chat.editTarget != nil else { return }
    let editOwner = chat.draft.ownerID
    let gate = EditAttachmentRewindGate()
    chat.messageEditRewindCompletionProbe = { await gate.hold($0) }
    let sentText = "edit-attachment-check-" + UUID().uuidString
    let sending = Task { await chat.sendEdit(sentText, attachments: []) }
    let entered = await waitFor("actual rewind response held", timeout: 25) { gate.entered != nil }
    check(entered && gate.entered == true && chat.isSendingEdit, "actual successful Gateway rewind is held before local completion")
    guard entered && gate.entered == true && chat.isSendingEdit else {
        sending.cancel(); gate.release(); _ = await sending.value
        chat.messageEditRewindCompletionProbe = nil; return
    }
    let late = chat.beginAttachmentPreparation(ownerID: editOwner)
    check(late == nil, "busy current edit draft rejects new preparation admission")
    if let late { chat.finishAttachmentPreparation(late) }
    guard let saved = chat.beginAttachmentPreparation(ownerID: normalOwner) else {
        check(false, "already selected saved normal draft remains admitted")
        sending.cancel(); gate.release(); _ = await sending.value
        chat.messageEditRewindCompletionProbe = nil; return
    }
    let bytes = await Task.detached {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }.value
    let attachment = OutgoingAttachment(fileName: "saved-normal.png", mimeType: "image/png", data: bytes)
    chat.appendPreparedAttachment(attachment, ownerID: normalOwner)
    chat.finishAttachmentPreparation(saved)
    check(chat.editTarget?.savedDraft.attachments == [attachment], "prepared saved-normal image is held by its actual owner")
    gate.release(); _ = await sending.value
    chat.messageEditRewindCompletionProbe = nil
    check(chat.editTarget == nil && !chat.isSendingEdit && chat.draft.ownerID == normalOwner && chat.draft.attachments == [attachment],
          "actual edit completion restores the prepared normal draft")
    do {
        let history = try await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": .number(200)])
        let message = history["messages"]?.array?.first { row in
            row["role"]?.string == "user" && (row["content"]?.array ?? []).contains { $0["text"]?.string == sentText }
        }
        check(message != nil, "real history contains the actual edited send")
        check(!(message?["content"]?.array ?? []).contains { $0["type"]?.string == "image" }, "saved-normal image is excluded from the earlier captured edit send")
    } catch { check(false, "actual edited history read completes") }
}
@MainActor func runEditSendAttachmentAdmissionChecks() async { await checkEditAttachmentAdmission() }
@MainActor func runDemoEditSendAttachmentAdmissionChecks() async { await checkEditAttachmentAdmission() }
#endif
