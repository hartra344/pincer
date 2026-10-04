import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Composer queued edit ownership")
struct ComposerEditAdmissionOwnershipTests {
    @Test func typingKeepsOwnerButEqualDraftReplacementAndCancelRejectOldAdmission() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = gateway.chat(for: "agent:main:queued-edit")
        let saved = ComposerDraft(text: "Normal")
        chat.editTarget = MessageEditTarget(messageId: "edit", entryId: "entry", originalText: "Edit", savedDraft: saved)
        chat.draft = ComposerDraft(text: "Edit")
        let owner = chat.draft.ownerID
        #expect(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit"))
        chat.draft.text = "Updated while still editing"
        #expect(chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit"))
        chat.draft = ComposerDraft(text: chat.draft.text)
        #expect(!chat.ownsDeferredSend(draftOwnerID: owner, editingMessageID: "edit"))
        let replacementOwner = chat.draft.ownerID
        chat.cancelEdit()
        #expect(!chat.ownsDeferredSend(draftOwnerID: replacementOwner, editingMessageID: "edit"))
        #expect(chat.draft.ownerID == saved.ownerID)
    }
}
