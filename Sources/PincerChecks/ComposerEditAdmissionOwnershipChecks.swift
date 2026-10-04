import Foundation
@testable import PincerKit

@MainActor func runComposerEditAdmissionOwnershipChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    let chat = gateway.chat(for: "agent:main:queued-edit")
    let saved = ComposerDraft(text: "Normal")
    chat.editTarget = MessageEditTarget(messageId: "edit", entryId: "entry", originalText: "Edit", savedDraft: saved)
    chat.draft = ComposerDraft(text: "Edit")
    let owner = chat.draft.ownerID
    check(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit"), "current editing owner is admitted by the actual Composer policy")
    chat.cancelEdit()
    check(!chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit") && chat.draft.ownerID == saved.ownerID,
          "Cancel rejects queued edit ownership without consuming the normal draft")
}

@MainActor func runDemoComposerEditAdmissionOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("queued edit Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "queued edit ownership connects to genuine Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    guard let user = chat.items.last(where: { $0.role == .user && !$0.isPending }) else {
        check(false, "actual Demo contains an editable user message"); return
    }
    chat.draft = ComposerDraft(text: "Normal")
    let saved = chat.draft
    guard chat.beginEdit(user.id) else { check(false, "actual Demo message enters edit mode"); return }
    let oldOwner = chat.draft.ownerID
    check(chat.ownsDeferredSend(draftOwnerID: oldOwner, editingMessageID: user.id), "current real Demo edit remains admissible")
    check(chat.beginEdit(user.id), "same message can be selected again")
    check(!chat.ownsDeferredSend(draftOwnerID: oldOwner, editingMessageID: user.id), "same-ID reselection cannot inherit old queued admission")
    let currentOwner = chat.draft.ownerID
    chat.cancelEdit()
    check(!chat.ownsDeferredSend(draftOwnerID: currentOwner, editingMessageID: user.id)
          && chat.draft.ownerID == saved.ownerID && chat.draft == saved, "real Demo Cancel preserves the saved normal draft")
}
