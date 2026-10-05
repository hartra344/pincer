#if DEBUG
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct EditSendAttachmentAdmissionTests {
    @MainActor
    final class Gate {
        var entered: Bool?
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func hold(_ success: Bool) async {
            entered = success
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { @MainActor in self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !predicate() {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test(arguments: ["active", "saved", "ordinary", "failure"])
    func actualComposerRejectsOnlyBusyEditDraftAdmission(mode: String) async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        try await wait { gateway.state.isConnected && gateway.bootstrapped }
        let source = gateway.chat(for: "agent:main:dashboard:garden")
        await source.load()
        let assistant = try #require(source.items.last { $0.role == .assistant && $0.isCommittedEntry })
        let key = try #require(await source.branch(from: assistant.id))
        let chat = gateway.chat(for: key)
        await chat.load()
        let user = try #require(chat.items.last {
            $0.role == .user && $0.isCommittedEntry && !$0.plainText.isEmpty && !$0.blocks.contains { if case .image = $0 { return true }; return false }
        })
        let transcriptId = try #require(user.transcriptId)
        let before = try await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": .number(200)])
        let original = try #require(before["messages"]?.array?.first { $0["__openclaw"]?["id"]?.string == transcriptId })
        let originalContent = try #require(original["content"]?.array)
        try #require(original["role"]?.string == "user" && originalContent.contains { $0["type"]?.string == "text" && $0["text"]?.string?.isEmpty == false })
        try #require(!originalContent.contains { $0["type"]?.string == "image" }, "The actual selected editable row has no images before rewind")
        chat.draft = ComposerDraft(text: "ordinary normal draft")
        let normalOwner = chat.draft.ownerID
        let queue = BoundedPreparationQueue<AttachmentIngestResult>()
        let savedIngest = ComposerAttachmentIngest.make(chat: chat, gateway: gateway, imageQueue: queue)
        try #require(ComposerAttachmentIngest.canAttach(chat: chat, gateway: gateway))
        if mode == "ordinary" {
            let png = await Task.detached {
                Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            }.value
            savedIngest.ingest([.data(png, type: .png, name: "late-edit.png")])
            try await wait { queue.activeCount == 0 }
            try #require(chat.draft.attachments.first?.fileName == "late-edit.png")
        }
        try #require(chat.beginEdit(user.id))
        if mode == "failure" {
            let target = try #require(chat.editTarget)
            chat.editTarget = MessageEditTarget(messageId: target.messageId, entryId: "missing-entry",
                                               originalText: target.originalText, savedDraft: target.savedDraft)
        }
        let gate = Gate()
        chat.messageEditRewindCompletionProbe = { await gate.hold($0) }
        let sentText = "owned-edit-send-" + UUID().uuidString
        let sending = Task { await chat.sendEdit(sentText, attachments: []) }
        do {
            try await wait { gate.entered != nil }
            try #require(chat.isSendingEdit && chat.editTarget != nil)
            try #require(gate.entered == (mode != "failure"))
            let png = await Task.detached {
                Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            }.value
            let ingestion = mode == "saved" ? savedIngest : ComposerAttachmentIngest.make(chat: chat, gateway: gateway, imageQueue: queue)
            if mode == "active" || mode == "failure" {
                #expect(!ComposerAttachmentIngest.canAttach(chat: chat, gateway: gateway), "An admitted edit must not offer new attachments to its captured edit draft")
            }
            if mode != "ordinary" { ingestion.ingest([.data(png, type: .png, name: "late-edit.png")]) }
            let admittedLateImage = queue.activeCount != 0
            if mode == "active" || mode == "failure" {
                #expect(chat.draftAttachmentPreparationCount == 0 && queue.activeCount == 0,
                        "Actual ingestion must reject busy current-edit preparation")
            }
            try await wait { queue.activeCount == 0 }
            if mode == "saved" || mode == "ordinary" {
                #expect(chat.editTarget?.savedDraft.attachments.count == 1 && chat.draft.attachments.isEmpty)
            } else if !chat.draft.attachments.isEmpty {
                // Diagnostic old path: the actual prepared image was admitted, so prove completion loss.
                #expect(chat.draft.attachments.first?.fileName == "late-edit.png")
            }
            gate.release()
            let outcome = await sending.value
            chat.messageEditRewindCompletionProbe = nil
            if mode == "failure" {
                if case .failed = outcome { #expect(chat.editTarget != nil && !chat.isSendingEdit) }
                else { Issue.record("actual missing rewind must fail") }
                #expect(ComposerAttachmentIngest.canAttach(chat: chat, gateway: gateway))
            } else {
                #expect(chat.editTarget == nil && chat.draft.ownerID == normalOwner && !chat.isSendingEdit)
                if mode == "saved" || mode == "ordinary" { #expect(chat.draft.attachments.first?.fileName == "late-edit.png") }
                if mode == "active" && admittedLateImage {
                    #expect(chat.draft.attachments.first?.fileName == "late-edit.png", "An admitted image that missed the send must not disappear")
                }
                let history = try await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": .number(200)])
                let message = history["messages"]?.array?.first { row in
                    row["role"]?.string == "user" && (row["content"]?.array ?? []).contains { $0["text"]?.string == sentText }
                }
                #expect(message != nil, "Real rewind completion is followed by the actual edited send")
                #expect(!(message?["content"]?.array ?? []).contains { $0["type"]?.string == "image" }, "The real send contains only the previously captured empty attachment list")
            }
        } catch {
            sending.cancel(); gate.release(); _ = await sending.value
            chat.messageEditRewindCompletionProbe = nil
            let drain = Task { @MainActor in try? await wait { queue.activeCount == 0 } }
            await drain.value
            throw error
        }
    }
}
#endif
