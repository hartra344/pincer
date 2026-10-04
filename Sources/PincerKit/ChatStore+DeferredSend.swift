import Foundation

extension ChatStore {
    /// A deferred input result may send only the same draft and editing context that admitted it.
    public func ownsDeferredSend(draftOwnerID: UUID, editingMessageID: String?) -> Bool {
        self.draft.ownerID == draftOwnerID && self.editTarget?.messageId == editingMessageID
    }
}
