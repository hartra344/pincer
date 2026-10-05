#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct EditSendAttachmentAdmissionTests {
    @Test func actualDisconnectedEditBlocksOnlyItsCurrentDraftPreparation() async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "owned offline", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        let chat = gateway.chat(for: "agent:main:owned-edit-admission")
        let normal = ComposerDraft(text: "ordinary normal draft")
        chat.draft = ComposerDraft(text: "current edit")
        let editOwner = chat.draft.ownerID
        chat.editTarget = MessageEditTarget(messageId: "owned-user", entryId: "owned-entry", originalText: "original", savedDraft: normal)
        var held = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        chat.messageEditRewindCompletionProbe = { success in
            #expect(!success, "actual disconnected request fails without opening a socket")
            held = true
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        }
        let operation = Task { await chat.sendEdit("current edit", attachments: []) }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while !held {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(chat.isSendingEdit && chat.editTarget != nil)
            let current = chat.beginAttachmentPreparation(ownerID: editOwner)
            #expect(current == nil, "busy active edit draft cannot admit another attachment")
            if let current { chat.finishAttachmentPreparation(current) }
            let saved = try #require(chat.beginAttachmentPreparation(ownerID: normal.ownerID))
            chat.finishAttachmentPreparation(saved)
            released = true; waiter?.resume(); waiter = nil
            let outcome = await operation.value
            if case .failed = outcome { #expect(!chat.isSendingEdit && chat.editTarget != nil && chat.draft.text == "current edit") }
            else { Issue.record("actual disconnected edit must retain current failure semantics") }
            let retry = try #require(chat.beginAttachmentPreparation(ownerID: editOwner))
            chat.finishAttachmentPreparation(retry)
            chat.messageEditRewindCompletionProbe = nil
        } catch {
            operation.cancel(); released = true; waiter?.resume(); waiter = nil
            _ = await operation.value
            chat.messageEditRewindCompletionProbe = nil
            throw error
        }
    }
}
#endif
