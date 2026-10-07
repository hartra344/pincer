#if DEBUG
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct EditSendNormalDraftPreparationTests {
    @Test func normalDraftRemainsAttachableWhileRealResendAcknowledgementWaits() async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while !condition() {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait { gateway.state.isConnected && gateway.bootstrapped }
        let chat = gateway.chat(for: "agent:main:dashboard:garden")
        await chat.load()
        let user = try #require(chat.items.first { $0.role == .user && $0.isCommittedEntry })
        chat.draft = ComposerDraft(text: "new normal draft")
        let normalOwner = chat.draft.ownerID
        try #require(chat.beginEdit(user.id))
        let gate = EditSendAttachmentAdmissionTests.Gate()
        await gateway.connection.setDemoResponseDelivery { method in
            if method == "chat.send" { await gate.hold(true) }
        }
        let queue = BoundedPreparationQueue<AttachmentIngestResult>()
        let sending = Task { await chat.sendEdit("actual edited send", attachments: []) }
        do {
            try await wait { gate.entered == true }
            try #require(chat.isSendingEdit && chat.editTarget == nil && chat.draft.ownerID == normalOwner)
            #expect(ComposerAttachmentIngest.canAttach(chat: chat, gateway: gateway))
            let png = await Task.detached {
                Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            }.value
            let ingest = ComposerAttachmentIngest.make(chat: chat, gateway: gateway, imageQueue: queue)
            ingest.ingest([.data(png, type: .png, name: "normal-after-edit.png")])
            try #require(chat.draftAttachmentPreparationCount == 1)
            try await wait { queue.activeCount == 0 }
            try #require(chat.draft.attachments.first?.fileName == "normal-after-edit.png")
            let prepared = chat.draft.attachments
            gate.release()
            let outcome = await sending.value
            if case .sent = outcome { }
            else { Issue.record("actual connected Demo resend must complete as sent") }
            #expect(!chat.isSendingEdit && chat.draft.ownerID == normalOwner && chat.draft.text == "new normal draft" && chat.draft.attachments == prepared)
            await gateway.connection.setDemoResponseDelivery(nil)
        } catch {
            sending.cancel(); gate.release(); _ = await sending.value
            await gateway.connection.setDemoResponseDelivery(nil)
            let drain = Task { @MainActor in try? await wait { queue.activeCount == 0 } }
            await drain.value
            throw error
        }
    }
}
#endif
