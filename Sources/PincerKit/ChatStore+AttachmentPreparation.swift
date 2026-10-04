import Foundation

extension ChatStore {
    public var draftAttachmentPreparationCount: Int {
        self.attachmentPreparationTokens.values.reduce(0) { $0 + ($1 == self.draft.ownerID ? 1 : 0) }
    }
    public var draftAttachmentPreparationError: String? {
        self.attachmentPreparationErrors[self.draft.ownerID]
    }

    private func ownsAttachmentDraft(_ ownerID: UUID) -> Bool {
        self.draft.ownerID == ownerID || self.editTarget?.savedDraft.ownerID == ownerID
    }

    /// Ephemeral reservations never enter the saved draft payload or Gateway protocol.
    public func beginAttachmentPreparation(ownerID: UUID) -> UUID? {
        guard self.ownsAttachmentDraft(ownerID), self.attachmentPreparationTokens.count < 64 else { return nil }
        let token = UUID()
        self.attachmentPreparationTokens[token] = ownerID
        // Selection is user intent before any provider result changes the payload. A late disk
        // restore must not replace this owner and silently discard the selected attachment.
        if self.draft.ownerID == ownerID { self.draftEdited = true }
        return token
    }
    public func finishAttachmentPreparation(_ token: UUID) {
        self.attachmentPreparationTokens.removeValue(forKey: token)
    }
    public func appendPreparedAttachment(_ attachment: OutgoingAttachment, ownerID: UUID) {
        if self.draft.ownerID == ownerID {
            self.draft.attachments.append(attachment)
        } else if var target = self.editTarget, target.savedDraft.ownerID == ownerID {
            target.savedDraft.attachments.append(attachment)
            self.editTarget = target
        }
    }
    public func reportAttachmentPreparationError(_ message: String?, ownerID: UUID) {
        guard self.ownsAttachmentDraft(ownerID) else { return }
        self.attachmentPreparationErrors[ownerID] = message
    }
    func pruneAttachmentPreparations() {
        let active = self.draft.ownerID
        let saved = self.editTarget?.savedDraft.ownerID
        self.attachmentPreparationTokens = self.attachmentPreparationTokens.filter { $0.value == active || $0.value == saved }
        self.attachmentPreparationErrors = self.attachmentPreparationErrors.filter { $0.key == active || $0.key == saved }
    }
}
