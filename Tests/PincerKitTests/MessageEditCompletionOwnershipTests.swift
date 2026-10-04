#if DEBUG
import Foundation
import Testing
@testable import PincerKit

/// Holds only the completion of the real Demo rewind, never its response or mutation.
@MainActor private final class EditRewindCompletionGate {
    var arrived: Bool?
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func hold(_ success: Bool) async {
        self.arrived = success
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.held = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.release() }
        }
    }
    func release() {
        self.released = true
        let continuation = self.held
        self.held = nil
        continuation?.resume()
    }
}

@MainActor
@Suite("Message edit completion ownership", .timeLimit(.minutes(2)))
struct MessageEditCompletionOwnershipTests {
    private func wait(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: ["cancel", "replacement", "ABA"])
    func obsoleteSuccessfulRewindCannotSendOrReplaceTheComposer(_ change: String) async throws {
        try await self.exercise(change: change, fail: false)
    }

    @Test(arguments: ["cancel", "replacement"])
    func obsoleteFailedRewindCannotPublishIntoTheNewComposer(_ change: String) async throws {
        try await self.exercise(change: change, fail: true)
    }

    @Test(arguments: [false, true])
    func currentCompletionKeepsExistingSuccessAndFailureMeaning(_ fail: Bool) async throws {
        try await self.exercise(change: "current", fail: fail)
    }

    private func exercise(change: String, fail: Bool) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded()
        defer { gateway.stop() }
        try await self.wait { gateway.state.isConnected && gateway.bootstrapped }
        let source = gateway.chat(for: "agent:main:dashboard:garden")
        await source.load()
        let assistant = try #require(source.items.last { $0.role == .assistant && $0.isCommittedEntry })
        let key = try #require(await source.branch(from: assistant.id))
        let chat = gateway.chat(for: key)
        await chat.load()
        let users = chat.items.filter { $0.role == .user && $0.isCommittedEntry }
        #expect(users.count == 2)
        let original = try #require(users.last)
        let replacement = try #require(users.first)
        let normalDraft = ComposerDraft(text: "normal draft before edit")
        chat.draft = normalDraft
        #expect(chat.beginEdit(original.id))
        if fail {
            let target = try #require(chat.editTarget)
            chat.editTarget = MessageEditTarget(messageId: target.messageId, entryId: "missing-entry",
                                               originalText: target.originalText, savedDraft: target.savedDraft)
        }
        let gate = EditRewindCompletionGate()
        chat.messageEditRewindCompletionProbe = { await gate.hold($0) }
        defer { gate.release(); chat.messageEditRewindCompletionProbe = nil }
        let oldText = "old admitted edit must not be resent after departure"
        let operation = Task { await chat.sendEdit(oldText, attachments: []) }
        defer { operation.cancel(); gate.release() }
        try await self.wait { gate.arrived != nil }
        #expect(gate.arrived == !fail, "gate follows the actual request success/error")
        #expect(chat.isSendingEdit)
        if change != "current" {
            chat.cancelEdit()
            #expect(chat.draft.text == normalDraft.text)
            chat.draft = ComposerDraft(text: "fresh normal draft")
            if change == "replacement" { #expect(chat.beginEdit(replacement.id)) }
            if change == "ABA" { #expect(chat.beginEdit(original.id)) }
            chat.draft.text = "fresh intent after departure"
            chat.errorMessage = "current feedback"
        }
        let freshDraft = chat.draft
        let freshTarget = chat.editTarget
        gate.release()
        let outcome = await operation.value // Actual edit task completion, not gate delivery.
        #expect(!chat.isSendingEdit)
        if change == "current" {
            if fail {
                guard case let .failed(message) = outcome else { Issue.record("current failure must fail"); return }
                #expect(chat.errorMessage == message && chat.editTarget == freshTarget && chat.draft == freshDraft)
            } else {
                guard case .sent = outcome else { Issue.record("current edit must send"); return }
                #expect(chat.editTarget == nil && chat.draft == normalDraft)
            }
        } else {
            #expect(chat.draft == freshDraft, "obsolete completion must preserve the fresh draft")
            #expect(chat.editTarget == freshTarget, "obsolete completion must preserve replacement selection, including ABA")
            #expect(chat.errorMessage == "current feedback", "obsolete error must not replace current feedback")
        }
        // Inspect genuine backend history after the actual operation; no local optimistic-row proxy.
        let history = try await gateway.connection.request("chat.history", ["sessionKey": .string(key)])
        let rows = try #require(history["messages"]?.array)
        let sentOld = rows.contains { value in
            value["role"]?.text == "user" && (value["content"]?.array ?? []).contains { $0["text"]?.text == oldText }
        }
        #expect(sentOld == (change == "current" && !fail), "actual history must contain an old resend only for current success")
        if !fail && change != "current" {
            #expect(rows.filter { $0["role"]?.text == "user" }.count == 1,
                    "the already-applied rewind remains authoritative; cancellation does not undo it")
        }
    }
}

#endif
