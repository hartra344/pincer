import Foundation
@testable import PincerKit

@MainActor
private func checkDeferredSendOwner(_ chat: ChatStore) {
    let saved = ComposerDraft(text: "Unsent normal draft")
    chat.editTarget = MessageEditTarget(messageId: "edit", entryId: "entry", originalText: "Editing", savedDraft: saved)
    chat.draft = ComposerDraft(text: "Editing")
    let owner = chat.draft.ownerID
    check(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit"), "actual editing draft admits its deferred send")
    chat.cancelEdit()
    check(!chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit") && chat.draft.ownerID == saved.ownerID,
          "actual edit cancellation rejects the old send and restores normal draft")
    chat.draft = ComposerDraft(text: saved.text)
    check(!chat.ownsDeferredSend(draftOwnerID: saved.ownerID, editingMessageID: nil),
          "equal-content replacement does not inherit a deferred send")
}

@MainActor
func runDeferredDictationSendChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    checkDeferredSendOwner(gateway.chat(for: "agent:main:deferred-send"))
}

@MainActor
func runDemoDeferredDictationSendChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("deferred send Demo", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "actual deferred send Demo connects"); return
    }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    guard let user = chat.items.last(where: { $0.role == .user && !$0.isPending }) else {
        check(false, "actual deferred send Demo contains an editable message"); return
    }
    chat.draft = ComposerDraft(text: "Unsent normal draft")
    guard chat.beginEdit(user.id), let target = chat.editTarget else {
        check(false, "actual seeded message enters editing"); return
    }
    let owner = chat.draft.ownerID
    check(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: target.messageId),
          "actual Demo editing admits the original draft send")
    chat.cancelEdit()
    check(!chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: target.messageId)
          && chat.draft.text == "Unsent normal draft", "actual Demo cancellation keeps the normal draft unsent")
}
