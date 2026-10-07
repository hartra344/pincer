import PincerKit

/// The shipped composer's attachment policy and callbacks, shared with deterministic fixtures.
@MainActor
enum ComposerAttachmentIngest {
    static func canAttach(chat: ChatStore, gateway: GatewayStore) -> Bool {
        !(chat.isSendingEdit && chat.editTarget != nil) && (gateway.state.isConnected || gateway.canPersistAttachments(bytes: 0))
    }

    static func make(chat: ChatStore, gateway: GatewayStore,
                     imageQueue: BoundedPreparationQueue<AttachmentIngestResult>? = nil) -> AttachmentIngest {
        let ownerID = chat.draft.ownerID
        return AttachmentIngest(limits: gateway.uploadLimits,
            limitsAreLastKnown: gateway.uploadLimitsAreLastKnown,
            imageQueue: imageQueue,
            owner: ownerID,
            reserve: { [weak chat] in
                guard let token = chat?.beginAttachmentPreparation(ownerID: ownerID) else { return nil }
                return { [weak chat] in chat?.finishAttachmentPreparation(token) }
            },
            add: { [weak chat] in chat?.appendPreparedAttachment($0, ownerID: ownerID) },
            report: { [weak chat] in chat?.reportAttachmentPreparationError($0, ownerID: ownerID) })
    }
}
