import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Attachment draft ownership")
struct AttachmentDraftOwnershipTests {
    private func fixture(headless: Bool = true) -> (ChatStore, GatewayStore, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Draft ownership", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let chat = ChatStore(sessionKey: "agent:main:draft-ownership", agentId: "main", gateway: gateway, headless: headless)
        return (chat, gateway, scratch)
    }

    private var attachment: OutgoingAttachment {
        OutgoingAttachment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000732")!, fileName: "owned.txt", mimeType: "text/plain", data: Data("owned".utf8))
    }

    @Test func activeDraftReservationCompletesExactlyOnceAndCanRetryAfterFailure() throws {
        let (chat, gateway, scratch) = self.fixture()
        defer { gateway.stop(); scratch.remove() }
        chat.draft.text = "Keep typing"
        let owner = chat.draft.ownerID
        let token = try #require(chat.beginAttachmentPreparation(ownerID: owner))
        #expect(chat.draftAttachmentPreparationCount == 1)
        chat.reportAttachmentPreparationError("Couldn’t read owned.txt.", ownerID: owner)
        chat.finishAttachmentPreparation(token)
        chat.finishAttachmentPreparation(token)
        #expect(chat.draftAttachmentPreparationCount == 0)
        #expect(chat.draftAttachmentPreparationError == "Couldn’t read owned.txt.")
        let retry = try #require(chat.beginAttachmentPreparation(ownerID: owner))
        chat.appendPreparedAttachment(self.attachment, ownerID: owner)
        chat.finishAttachmentPreparation(retry)
        #expect(chat.draft.attachments == [self.attachment])
        #expect(chat.draft.text == "Keep typing" && chat.draftAttachmentPreparationCount == 0)
    }

    @Test(arguments: ["New draft", "Old draft"])
    func replacedDraftRejectsOldSuccessErrorAndReservation(_ replacement: String) throws {
        let (chat, gateway, scratch) = self.fixture()
        defer { gateway.stop(); scratch.remove() }
        chat.draft.text = "Old draft"
        let owner = chat.draft.ownerID
        let token = try #require(chat.beginAttachmentPreparation(ownerID: owner))
        chat.draft = ComposerDraft(text: replacement)
        #expect(chat.draftAttachmentPreparationCount == 0)
        #expect(chat.beginAttachmentPreparation(ownerID: owner) == nil)
        chat.appendPreparedAttachment(self.attachment, ownerID: owner)
        chat.reportAttachmentPreparationError("Old failed preparation", ownerID: owner)
        chat.finishAttachmentPreparation(token)
        #expect(chat.draft.text == replacement && chat.draft.attachments.isEmpty)
        #expect(chat.draftAttachmentPreparationError == nil && chat.draftAttachmentPreparationCount == 0)
    }

    @Test func savedNormalDraftReceivesItsImageDuringEditAndCancelRestoresIt() throws {
        let (chat, gateway, scratch) = self.fixture()
        defer { gateway.stop(); scratch.remove() }
        chat.draft.text = "Normal unsent draft"
        let normal = chat.draft
        let normalToken = try #require(chat.beginAttachmentPreparation(ownerID: normal.ownerID))
        // MessageEditTarget is the actual model's saved-draft representation, not a parallel fixture store.
        chat.editTarget = MessageEditTarget(messageId: "user", entryId: "entry", originalText: "Edit text", savedDraft: normal)
        chat.draft = ComposerDraft(text: "Edit text")
        let editOwner = chat.draft.ownerID
        let editToken = try #require(chat.beginAttachmentPreparation(ownerID: editOwner))
        chat.appendPreparedAttachment(self.attachment, ownerID: normal.ownerID)
        chat.finishAttachmentPreparation(normalToken)
        #expect(chat.draft.text == "Edit text" && chat.draft.attachments.isEmpty)
        #expect(chat.draftAttachmentPreparationCount == 1)
        #expect(chat.editTarget?.savedDraft.attachments == [self.attachment])
        chat.cancelEdit()
        #expect(chat.draft.ownerID == normal.ownerID && chat.draft.text == "Normal unsent draft")
        #expect(chat.draft.attachments == [self.attachment] && chat.draftAttachmentPreparationCount == 0)
        chat.appendPreparedAttachment(self.attachment, ownerID: editOwner)
        chat.reportAttachmentPreparationError("Discarded edit error", ownerID: editOwner)
        chat.finishAttachmentPreparation(editToken)
        #expect(chat.draft.attachments.count == 1 && chat.draftAttachmentPreparationError == nil)
    }

    @Test func pendingNormalDraftRemainsPendingAfterCancelEdit() throws {
        let (chat, gateway, scratch) = self.fixture()
        defer { gateway.stop(); scratch.remove() }
        let normal = ComposerDraft(text: "Normal")
        chat.draft = normal
        let token = try #require(chat.beginAttachmentPreparation(ownerID: normal.ownerID))
        chat.editTarget = MessageEditTarget(messageId: "user", entryId: "entry", originalText: "Edit", savedDraft: normal)
        chat.draft = ComposerDraft(text: "Edit")
        #expect(chat.draftAttachmentPreparationCount == 0)
        chat.cancelEdit()
        #expect(chat.draftAttachmentPreparationCount == 1)
        chat.appendPreparedAttachment(self.attachment, ownerID: normal.ownerID)
        chat.finishAttachmentPreparation(token)
        #expect(chat.draftAttachmentPreparationCount == 0 && chat.draft.attachments == [self.attachment])
    }

    @Test func reservationsAreBoundedAndReleaseCapacityForRetry() throws {
        let (chat, gateway, scratch) = self.fixture()
        defer { gateway.stop(); scratch.remove() }
        let owner = chat.draft.ownerID
        var tokens: [UUID] = []
        for _ in 0..<64 { tokens.append(try #require(chat.beginAttachmentPreparation(ownerID: owner))) }
        #expect(chat.draftAttachmentPreparationCount == 64)
        #expect(chat.beginAttachmentPreparation(ownerID: owner) == nil)
        chat.finishAttachmentPreparation(tokens.removeLast())
        let replacement = try #require(chat.beginAttachmentPreparation(ownerID: owner))
        #expect(chat.draftAttachmentPreparationCount == 64)
        for token in tokens { chat.finishAttachmentPreparation(token) }
        chat.finishAttachmentPreparation(replacement)
        #expect(chat.draftAttachmentPreparationCount == 0)
    }

    @Test func acceptingPreparationInEmptyDraftProtectsIntentFromPendingDiskRestore() throws {
        let (chat, gateway, scratch) = self.fixture(headless: false)
        defer { chat.draftSaveTask?.cancel(); gateway.stop(); scratch.remove() }
        #expect(chat.draft.isEmpty && !chat.draftEdited)
        let owner = chat.draft.ownerID
        #expect(chat.beginAttachmentPreparation(ownerID: UUID()) == nil)
        #expect(!chat.draftEdited, "A refused stale request cannot block restoring a real saved draft")
        let token = try #require(chat.beginAttachmentPreparation(ownerID: owner))
        #expect(chat.draftEdited,
                "restoreDraft checks this actual marker after its disk await; a selected image is user intent even before bytes arrive")
        #expect(chat.draft.isEmpty && chat.draftAttachmentPreparationCount == 1)
        chat.finishAttachmentPreparation(token)
        #expect(chat.draftEdited, "Finishing preparation cannot re-enable a late saved-draft overwrite")
    }

    @Test func explicitEqualPayloadOwnerReplacementProtectsRestoreWithoutWritingUnchangedPayload() {
        let (chat, gateway, scratch) = self.fixture(headless: false)
        defer { chat.draftSaveTask?.cancel(); gateway.stop(); scratch.remove() }
        let original = chat.draft
        #expect(!chat.draftEdited && chat.draftSaveTask == nil)
        chat.draft = ComposerDraft()
        #expect(chat.draft == original && chat.draft.ownerID != original.ownerID)
        #expect(chat.draftEdited, "A deliberate empty replacement still supersedes an awaited disk restore")
        #expect(chat.draftSaveTask == nil, "Ephemeral ownership alone does not require rewriting equal disk contents")
    }

    @Test func installingRestoredDraftDoesNotInventNewUserIntent() throws {
        let (chat, gateway, scratch) = self.fixture(headless: false)
        defer { chat.draftSaveTask?.cancel(); gateway.stop(); scratch.remove() }
        chat.restoringDraft = true
        chat.draft = ComposerDraft(text: "Restored text")
        #expect(!chat.draftEdited && chat.draftSaveTask == nil)
        chat.restoringDraft = false
        let saved = chat.draft
        chat.editTarget = MessageEditTarget(messageId: "user", entryId: "entry", originalText: "Edit", savedDraft: saved)
        chat.restoringDraft = true
        chat.draft = ComposerDraft(text: "Edit")
        chat.restoringDraft = false
        let token = try #require(chat.beginAttachmentPreparation(ownerID: saved.ownerID))
        #expect(!chat.draftEdited, "Preparation for a saved normal draft does not claim a new edit draft")
        chat.finishAttachmentPreparation(token)
    }

    @Test func ephemeralOwnerDoesNotChangeDraftContentEquality() {
        let first = ComposerDraft(text: "same", attachments: [self.attachment])
        let second = ComposerDraft(text: "same", attachments: first.attachments)
        #expect(first.ownerID != second.ownerID)
        #expect(first == second && Set([first, second]).count == 1)
    }
}
