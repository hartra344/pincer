import Foundation
@testable import PincerKit

@MainActor
private func checkAttachmentDraftOwnership(_ chat: ChatStore) {
    chat.draft = ComposerDraft(text: "A draft with a selected attachment")
    let owner = chat.draft.ownerID
    guard let token = chat.beginAttachmentPreparation(ownerID: owner) else {
        check(false, "actual draft preparation admits its owner"); return
    }
    chat.draft.text += " and more typing"
    check(chat.draft.ownerID == owner && chat.draftAttachmentPreparationCount == 1,
          "typing keeps the actual draft reservation")
    let media = OutgoingAttachment(fileName: "note.txt", mimeType: "text/plain", data: Data("note".utf8))
    chat.appendPreparedAttachment(media, ownerID: owner)
    chat.finishAttachmentPreparation(token)
    chat.finishAttachmentPreparation(token)
    check(chat.draft.attachments == [media] && chat.draftAttachmentPreparationCount == 0,
          "actual preparation releases exactly once and keeps the selected media")
    chat.draft = ComposerDraft(text: "replacement")
    chat.appendPreparedAttachment(media, ownerID: owner)
    chat.reportAttachmentPreparationError("old failure", ownerID: owner)
    check(chat.draft.attachments.isEmpty && chat.draftAttachmentPreparationError == nil,
          "replacement draft rejects old media and old errors")
}

@MainActor
func runAttachmentDraftOwnershipChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    checkAttachmentDraftOwnership(gateway.chat(for: "agent:main:dashboard:trip"))
}

@MainActor
func runDemoAttachmentDraftOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:trip"
    guard await waitFor("attachment ownership Demo", timeout: 25, {
        gateway.state.isConnected && gateway.sessions[key] != nil
    }) else { check(false, "actual attachment ownership Demo connects"); return }
    let chat = gateway.chat(for: key)
    await chat.load()
    check(chat.hasLoaded, "actual seeded chat loads for attachment ownership")
    checkAttachmentDraftOwnership(chat)
}
