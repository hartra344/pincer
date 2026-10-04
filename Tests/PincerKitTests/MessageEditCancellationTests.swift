#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Message edit cancellation controls", .timeLimit(.minutes(2)))
struct MessageEditCancellationTests {
    @Test func ordinaryManualHistoryLoadStillPublishesCurrentFailure() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded()
        defer { gateway.stop() }
        try await self.wait { gateway.state.isConnected && gateway.bootstrapped }
        let missing = gateway.chat(for: "agent:main:missing-edit-history-control")
        missing.errorMessage = "previous feedback"
        await missing.load(force: true)
        #expect(missing.errorMessage != nil && missing.errorMessage != "previous feedback",
                "ordinary current history failure remains publishable")
        let current = gateway.chat(for: "agent:main:dashboard:garden")
        current.errorMessage = "previous feedback"
        await current.load(force: true)
        #expect(current.hasLoaded && current.errorMessage == nil,
                "ordinary successful history load still clears unchanged old feedback")
    }

    @Test func precanceledEditDoesNotAdmitOrPublish() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        let chat = gateway.chat(for: "agent:main:edit-cancel-control")
        chat.editTarget = MessageEditTarget(messageId: "u", entryId: "entry", originalText: "old", savedDraft: ComposerDraft(text: "normal"))
        chat.draft.text = "edited"
        chat.errorMessage = "current"
        let task = Task { await chat.sendEdit("old", attachments: []) }
        task.cancel()
        _ = await task.value
        #expect(!chat.isSendingEdit && chat.editTarget?.messageId == "u")
        #expect(chat.draft.text == "edited" && chat.errorMessage == "current")
    }

    @Test(arguments: [false, true])
    func currentSavedDraftUpdatesSurviveAndCanceledTasksCannotResend(_ cancel: Bool) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded()
        defer { gateway.stop() }
        try await self.wait { gateway.state.isConnected && gateway.bootstrapped }
        let source = gateway.chat(for: "agent:main:dashboard:garden")
        await source.load()
        let assistant = try #require(source.items.last { $0.role == .assistant && $0.isCommittedEntry })
        let key = try #require(await source.branch(from: assistant.id))
        let chat = gateway.chat(for: key)
        await chat.load()
        let user = try #require(chat.items.last { $0.role == .user && $0.isCommittedEntry })
        #expect(chat.beginEdit(user.id))
        var arrived = false
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
        func release() { released = true; let held = continuation; continuation = nil; held?.resume() }
        chat.messageEditRewindCompletionProbe = { success in
            #expect(success)
            arrived = true
            await withCheckedContinuation { held in
                if released || Task.isCancelled { held.resume() } else { continuation = held }
            }
        }
        defer { release(); chat.messageEditRewindCompletionProbe = nil }
        let task = Task { await chat.sendEdit("current admitted edit", attachments: []) }
        defer { task.cancel(); release() }
        try await self.wait { arrived }
        var updated = try #require(chat.editTarget)
        updated.savedDraft.text = "latest saved normal draft"
        chat.editTarget = updated // Same-selection attachment completion uses this path too.
        let attachment = OutgoingAttachment(fileName: "note.txt", mimeType: "text/plain", data: Data([1, 2, 3]))
        chat.appendPreparedAttachment(attachment, ownerID: updated.savedDraft.ownerID)
        updated = try #require(chat.editTarget)
        let before = chat.draft
        if cancel { task.cancel() }
        release()
        let outcome = await task.value
        #expect(!chat.isSendingEdit)
        if cancel {
            #expect(chat.editTarget == updated && chat.draft == before)
            #expect(chat.errorMessage == nil)
        } else {
            guard case .sent = outcome else { Issue.record("current same-selection edit must send"); return }
            #expect(chat.editTarget == nil && chat.draft.text == "latest saved normal draft")
            #expect(chat.draft.attachments == [attachment], "same-selection saved-draft attachment completion survives")
        }
        let history = try await gateway.connection.request("chat.history", ["sessionKey": .string(key)])
        let users = try #require(history["messages"]?.array).filter { $0["role"]?.text == "user" }
        #expect(users.count == (cancel ? 1 : 2))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(20))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
