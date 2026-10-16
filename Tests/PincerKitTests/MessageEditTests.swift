import Foundation
import Testing
@testable import PincerKit

/// Holds `chat.history` replies after they arrive; every probe call parks until `release()`.
@MainActor private final class HistoryReplyHold {
    var arrived = false
    var failsOnRelease = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async throws {
        self.arrived = true
        await withCheckedContinuation { continuation in
            if self.released { continuation.resume() } else { self.held = continuation }
        }
        if self.failsOnRelease { throw GatewayError.notConnected }
    }
    func release() {
        self.released = true
        let continuation = self.held
        self.held = nil
        continuation?.resume()
    }
}

/// #41: Branch from Here, Edit & Resend and Regenerate, against the demo Gateway's seeded garden chat
/// (two user turns; every test forks it first so the seed stays untouched).
@MainActor
@Suite("Message edit, regenerate, branch")
struct MessageEditTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    static let garden = "agent:main:dashboard:garden"

    /// Polls until `condition` holds and records a loud failure if it never does, so a starved
    /// scheduler shows up as a timeout naming the wait rather than as a later, unrelated assertion.
    func settle(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("settle timed out after 30s", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func instantPacingDemoIsADemoWithoutRunDelays() async {
        #expect(GatewayProfile.demoInstantPacing().isDemo)
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        let before = self.messages(chat, .assistant).count
        _ = await chat.sendMessage("pacing probe", attachments: [])
        await self.settle { !chat.isRunning && self.messages(chat, .assistant).count > before }
        await self.finish(gateway)
    }

    func connected() async -> GatewayStore {
        let gateway = GatewayStore(profile: GatewayProfile.demoInstantPacing(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        gateway.start()
        await self.settle { gateway.state.isConnected && gateway.sessions[Self.garden] != nil }
        return gateway
    }

    func finish(_ gateway: GatewayStore) async {
        gateway.stop()
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }

    func loaded(_ gateway: GatewayStore, _ key: String) async -> ChatStore {
        let chat = gateway.chat(for: key)
        await chat.load()
        return chat
    }

    func messages(_ chat: ChatStore, _ role: ChatRole) -> [ChatItem] {
        chat.items.filter { $0.role == role && $0.transcriptId != nil }
    }

    @Test func branchAtUserMessageForksBeforeItAndFillsTheComposer() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let user = self.messages(source, .user).last!
        let key = await source.branch(from: user.id)
        #expect(key != nil && key != Self.garden && gateway.selectedKey == key)
        let fork = await self.loaded(gateway, key ?? "")
        #expect(fork.items.count == 2)
        #expect(fork.draft.text == user.plainText)
        await self.finish(gateway)
    }

    @Test func branchAtAssistantMessageForksBeforeTheNextUserMessage() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let key = await source.branch(from: self.messages(source, .assistant).first!.id)
        let fork = await self.loaded(gateway, key ?? "")
        #expect(fork.items.count == 2 && fork.draft.text.isEmpty)
        await self.finish(gateway)
    }

    @Test func branchAtTheTailForksTheWholeChat() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let key = await source.branch(from: self.messages(source, .assistant).last!.id)
        #expect(key != nil)
        #expect(gateway.sessions[key ?? ""]?.raw["forkedFromParent"] == true)
        let fork = await self.loaded(gateway, key ?? "")
        #expect(fork.items.count == 4 && fork.draft.text.isEmpty)
        #expect(source.items.count == 4)
        await self.finish(gateway)
    }

    @Test func branchFailureSetsTheErrorAndChangesNothing() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let before = gateway.sessions.count
        var item = source.items[0]
        item.transcriptId = "missing-entry"
        source.items[0] = item
        let key = await source.branch(from: item.id)
        #expect(key == nil && source.errorMessage?.hasPrefix("Couldn’t branch") == true)
        #expect(gateway.sessions.count == before && gateway.selectedKey != nil)
        await self.finish(gateway)
    }

    @Test func availability() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let users = self.messages(source, .user), assistants = self.messages(source, .assistant)
        #expect(source.canBranchMessages && source.canRewindMessages)
        #expect(source.canEdit(users[0].id) && !source.canEdit(assistants[0].id))
        #expect(source.canRegenerate(assistants[1].id) && !source.canRegenerate(assistants[0].id) && !source.canRegenerate(users[1].id))
        await self.finish(gateway)
    }

    @Test func beginAndCancelEditRestoreTheDraft() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        let user = self.messages(chat, .user).last!
        chat.draft = ComposerDraft(text: "half-written")
        chat.replyTarget = ReplyTarget(messageId: "x", senderLabel: "s", preview: "p", isAssistant: false)
        #expect(chat.beginEdit(user.id))
        #expect(chat.editTarget?.originalText == user.plainText && chat.draft.text == user.plainText && chat.replyTarget == nil)
        chat.cancelEdit()
        #expect(chat.editTarget == nil && chat.draft.text == "half-written" && chat.items.count == 4)
        await self.finish(gateway)
    }

    @Test func sendingAnEditRewindsThenSendsAndForgetsTheCache() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let key = await source.branch(from: self.messages(source, .assistant).last!.id) ?? ""
        let chat = await self.loaded(gateway, key)
        await chat.saveToCache()
        let user = self.messages(chat, .user).last!
        #expect(chat.beginEdit(user.id))
        let generation = gateway.cacheGeneration(of: key)
        let outcome = await chat.sendEdit("an edited question", attachments: [])
        guard case .sent = outcome else { Issue.record("not sent: \(outcome)"); return }
        #expect(chat.editTarget == nil)
        #expect(gateway.cacheGeneration(of: key) > generation)
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && self.messages(chat, .user).count == 2 }
        #expect(self.messages(chat, .user).map(\.plainText).last == "an edited question")
        #expect(!chat.items.contains { $0.plainText == user.plainText })
        await self.finish(gateway)
    }

    @Test func aFailedRewindKeepsEditMode() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        let user = self.messages(chat, .user).last!
        #expect(chat.beginEdit(user.id))
        var target = chat.editTarget!
        target = MessageEditTarget(messageId: target.messageId, entryId: "missing-entry", originalText: target.originalText, savedDraft: target.savedDraft)
        chat.editTarget = target
        let outcome = await chat.sendEdit("nope", attachments: [])
        guard case let .failed(message) = outcome else { Issue.record("expected failure: \(outcome)"); return }
        #expect(message.hasPrefix("Couldn’t edit") && chat.editTarget != nil && chat.errorMessage == message)
        #expect(chat.items.count == 4)
        await self.finish(gateway)
    }

    @Test func regenerateRewindsAndResendsTheSameMessage() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        let user = self.messages(chat, .user).last!
        let reply = self.messages(chat, .assistant).last!
        #expect(await chat.regenerate(reply.id))
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && self.messages(chat, .user).count == 2 }
        let users = self.messages(chat, .user)
        #expect(users.count == 2 && users.last?.plainText == user.plainText)
        #expect(chat.items.last?.id != reply.id)
        await self.finish(gateway)
    }

    // MARK: In-chat branch navigation

    @Test func seededChatListsItsBranchesActiveFirst() async {
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        await chat.refreshBranches()
        #expect(chat.branches.count == 3 && chat.hasBranches)
        let dates = chat.branches.compactMap(\.updatedAt)
        #expect(dates == dates.sorted(), "oldest first, whichever branch is active")
        #expect(chat.activeBranchNumber == chat.branches.firstIndex { $0.active }.map { $0 + 1 })
        #expect(chat.canListBranches && chat.canSwitchBranches)
        await self.finish(gateway)
    }

    @Test func switchingBranchesReloadsTheTranscript() async {
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        await chat.refreshBranches()
        guard let other = chat.branches.first(where: { !$0.active }) else { Issue.record("no inactive branch"); return }
        let before = (texts: chat.items.map(\.plainText), branchIds: chat.branches.map(\.leafEntryId))
        #expect(await chat.switchBranch(to: other.leafEntryId))
        await self.settle { chat.items.map(\.plainText) != before.texts && chat.hasLoaded }
        #expect(chat.items.map(\.plainText) != before.texts)
        #expect(chat.branches.first { $0.active }?.leafEntryId == other.leafEntryId && chat.branches.count == 3)
        #expect(chat.branches.map(\.leafEntryId) == before.branchIds, "order doesn't change with the active branch")
        #expect(!(await chat.switchBranch(to: other.leafEntryId)), "the active branch can't be switched to")
        await self.finish(gateway)
    }

    @Test func aBranchFailureSetsTheErrorAndKeepsTheTranscript() async {
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        await chat.refreshBranches()
        let before = chat.items.map(\.plainText)
        chat.branches.append(SessionBranch(leafEntryId: "missing-leaf", headline: "gone", messageCount: 1, active: false))
        #expect(!(await chat.switchBranch(to: "missing-leaf")))
        #expect(chat.errorMessage?.hasPrefix("Couldn’t switch branch") == true && chat.items.map(\.plainText) == before)
        await self.finish(gateway)
    }

    @Test func editingCreatesABranchYouCanSwitchBackTo() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        await chat.refreshBranches()
        #expect(!chat.hasBranches)
        let original = chat.items.map(\.plainText)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("something else", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 && chat.activeBranchNumber == 2 }
        #expect(chat.branches.count == 2 && chat.activeBranchNumber == 2, "the newest branch is last and active")
        guard let old = chat.branches.first(where: { !$0.active }) else { return }
        #expect(await chat.switchBranch(to: old.leafEntryId))
        await self.settle { chat.items.map(\.plainText) == original }
        #expect(chat.items.map(\.plainText) == original)
        await self.finish(gateway)
    }

    /// #1010: a history reply that left the Gateway before a branch switch must not overwrite the switched branch.
    @Test func staleHistoryReplyCannotOverwriteASwitchedBranch() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        await chat.refreshBranches()
        let original = chat.items.map(\.plainText)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("something else", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 && chat.activeBranchNumber == 2 }
        guard let old = chat.branches.first(where: { !$0.active }) else { Issue.record("no old branch"); return }
        let edited = chat.items.map(\.plainText)
        #expect(edited != original)

        await self.settle { gateway.invalidatingTranscripts.isEmpty && chat.loadTask == nil }
        let held = HistoryReplyHold()
        chat.historyResponseProbe = { try await held.hold() }
        let stale = Task { await chat.load(force: true) } // Replied with the edited branch, held before applying.
        await self.settle { held.arrived }
        chat.historyResponseProbe = nil
        #expect(await chat.switchBranch(to: old.leafEntryId))
        await self.settle { chat.items.map(\.plainText) == original }
        held.release()
        await stale.value
        #expect(chat.items.map(\.plainText) == original, "the older reply must be dropped")
        await self.finish(gateway)
    }

    /// #1010: a branch switch arriving while another invalidation of the chat is mid-fetch must still reload last.
    @Test func branchSwitchDuringAnInFlightInvalidationStillLoadsTheSwitchedBranch() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        await chat.refreshBranches()
        let original = chat.items.map(\.plainText)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("something else", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 && chat.activeBranchNumber == 2 }
        guard let old = chat.branches.first(where: { !$0.active }) else { Issue.record("no old branch"); return }
        await self.settle { gateway.invalidatingTranscripts.isEmpty && chat.loadTask == nil }

        let held = HistoryReplyHold()
        chat.historyResponseProbe = { try await held.hold() }
        let key = chat.sessionKey
        let inFlight = Task { await gateway.transcriptChanged(key: key, change: .changed(editorText: nil)) }
        await self.settle { held.arrived }
        chat.historyResponseProbe = nil
        #expect(await chat.switchBranch(to: old.leafEntryId))
        held.release() // The in-flight reload now applies a reply fetched before the switch.
        await inFlight.value
        await self.settle { chat.items.map(\.plainText) == original }
        #expect(chat.items.map(\.plainText) == original, "the switch's reload must run after the in-flight one")
        await self.finish(gateway)
    }

    /// #1010: a fetch superseded by a newer load must not show its failure while the newer one is still loading.
    @Test func supersededHistoryFailureStaysSilent() async {
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        await self.settle { gateway.invalidatingTranscripts.isEmpty && chat.loadTask == nil }
        let failing = HistoryReplyHold()
        failing.failsOnRelease = true
        let newer = HistoryReplyHold()
        var calls = 0
        chat.historyResponseProbe = { calls += 1; try await (calls == 1 ? failing : newer).hold() }
        let first = Task { await chat.load(force: true) }
        await self.settle { failing.arrived }
        let second = Task { await chat.load(force: true) }
        await self.settle { newer.arrived }
        failing.release()
        await first.value
        #expect(chat.errorMessage == nil, "a superseded failure shows no banner")
        newer.release()
        await second.value
        #expect(chat.errorMessage == nil && chat.hasLoaded)
        chat.historyResponseProbe = nil
        await self.finish(gateway)
    }

    /// #1010: the `sessions.changed` echo of an edit or switch (during or after the RPC path's reload) must not blank twice.
    @Test(arguments: [true, false]) func echoOfABranchSwitchBlanksTheTranscriptOnce(_ duringReload: Bool) async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        await chat.refreshBranches()
        let original = chat.items.map(\.plainText)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("something else", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 && chat.activeBranchNumber == 2 }
        await self.settle { gateway.invalidatingTranscripts.isEmpty && chat.loadTask == nil }
        let key = chat.sessionKey
        gateway.lastTranscriptInvalidation[key] = nil // The setup's own echo window is over.
        let before = chat.fullReloadCount
        let held = HistoryReplyHold()
        if duringReload { chat.historyResponseProbe = { try await held.hold() } }
        let rpc = Task { await gateway.transcriptChanged(key: key, change: .changed(editorText: nil)) }
        if duringReload {
            await self.settle { held.arrived }
            chat.historyResponseProbe = nil
            await gateway.transcriptChanged(key: key, change: .changed(editorText: nil)) // The echo, queued.
            held.release()
            await rpc.value
        } else {
            await rpc.value
            await gateway.transcriptChanged(key: key, change: .changed(editorText: nil)) // The echo, after.
        }
        #expect(chat.fullReloadCount - before == 1, "one blank-and-refill for a change and its echo")
        await self.settle { !chat.items.isEmpty && chat.hasLoaded }
        await self.finish(gateway)
    }

    /// #1010: an authority-less echo queued behind an edit's reload keeps the edit's feedback authority.
    @Test func echoKeepsTheEditsFeedbackAuthorityForTheRerun() async {
        let gateway = await self.connected()
        let chat = await self.loaded(gateway, Self.garden)
        await self.settle { gateway.invalidatingTranscripts.isEmpty && chat.loadTask == nil }
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        gateway.lastTranscriptInvalidation[chat.sessionKey] = nil
        let owner = UUID()
        chat.messageEditSendOwner = owner
        let authority = ChatStore.MessageEditFeedbackAuthority(owner: owner, selection: chat.messageEditSelection)
        let first = HistoryReplyHold()
        let second = HistoryReplyHold()
        second.failsOnRelease = true
        var calls = 0
        chat.historyResponseProbe = { calls += 1; try await (calls == 1 ? first : second).hold() }
        let key = chat.sessionKey
        let rpc = Task { await gateway.transcriptChanged(key: key, change: .changed(editorText: nil), feedbackAuthority: authority) }
        await self.settle { first.arrived }
        await gateway.transcriptChanged(key: key, change: .changed(editorText: nil)) // The echo, no authority.
        first.release()
        await self.settle { second.arrived }
        chat.cancelEdit() // The edit is no longer current when the rerun's fetch fails.
        second.release()
        await rpc.value
        chat.historyResponseProbe = nil
        #expect(chat.errorMessage == nil, "the rerun's failure is the departed edit's, so no banner")
        await self.finish(gateway)
    }

    @Test func branchAnchorIsTheLastUserMessageOnceThereAreBranches() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        await chat.refreshBranches()
        #expect(!chat.hasBranches && chat.branchAnchorId == nil)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("something else", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 && chat.activeBranchNumber == 2 }
        #expect(chat.hasBranches)
        let edited = self.messages(chat, .user).last?.transcriptId
        #expect(chat.branchAnchorId != nil && chat.branchAnchorId == edited)
        // A later message on the branch doesn't move the switcher off the edited one, even after a reload.
        _ = await chat.sendMessage("and a follow-up")
        await self.settle { !chat.isRunning && self.messages(chat, .user).count == 3 && chat.items.last?.role == .assistant }
        await chat.load(force: true)
        #expect(self.messages(chat, .user).count == 3 && chat.branchAnchorId == edited)
        await self.finish(gateway)
    }

    /// #429: the rewind reload can land before the live echo; neither may leave the edit pending.
    @Test func editBranchReplyLeavesNothingPending() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let key = await source.branch(from: self.messages(source, .assistant).last!.id) ?? ""
        let chat = await self.loaded(gateway, key)
        #expect(chat.beginEdit(self.messages(chat, .user).last!.id))
        _ = await chat.sendEdit("edited while a reload races", attachments: [])
        await chat.load(force: true)
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.branches.count == 2 }
        #expect(chat.branches.count == 2)
        #expect(!chat.items.contains { $0.isPending })
        await chat.load(force: true)
        #expect(!chat.items.contains { $0.isPending })
        #expect(!gateway.outbox.entries.contains { $0.sessionKey == key })
        await self.finish(gateway)
    }

    // MARK: Review fixes

    func editableFork(_ gateway: GatewayStore) async -> (chat: ChatStore, user: ChatItem) {
        let source = await self.loaded(gateway, Self.garden)
        let chat = await self.loaded(gateway, await source.branch(from: self.messages(source, .assistant).last!.id) ?? "")
        return (chat, self.messages(chat, .user).last!)
    }

    @Test func afterSendingAnEditTheOldDraftComesBack() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        chat.draft = ComposerDraft(text: "half-written")
        #expect(chat.beginEdit(user.id))
        _ = await chat.sendEdit("edited", attachments: [])
        #expect(chat.draft.text == "half-written" && chat.editTarget == nil && !chat.isSendingEdit)
        await self.finish(gateway)
    }

    @Test func aFailedRewindKeepsTheEditedText() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        #expect(chat.beginEdit(user.id))
        let target = chat.editTarget!
        chat.editTarget = MessageEditTarget(messageId: target.messageId, entryId: "missing-entry", originalText: target.originalText, savedDraft: target.savedDraft)
        chat.draft = ComposerDraft(text: "my edit")
        _ = await chat.sendEdit("my edit", attachments: [])
        #expect(chat.draft.text == "my edit" && chat.editTarget != nil && !chat.isSendingEdit)
        await self.finish(gateway)
    }

    @Test func aSecondSendEditWhileOneIsRunningIsIgnored() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        #expect(chat.beginEdit(user.id))
        async let first = chat.sendEdit("once", attachments: [])
        // Wait for the first edit to actually be in flight; a single yield doesn't guarantee the child task started.
        var yields = 0
        while !chat.isSendingEdit, yields < 100_000 { await Task.yield(); yields += 1 }
        #expect(chat.isSendingEdit, "first edit never went in flight")
        let second = await chat.sendEdit("twice", attachments: [])
        let firstOutcome = await first
        if case .sent = firstOutcome {} else { Issue.record("first edit not sent: \(firstOutcome)") }
        guard case .failed = second else { Issue.record("second edit should be refused: \(second)"); return }
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant }
        #expect(chat.items.filter { $0.plainText == "twice" }.isEmpty)
        #expect(chat.items.filter { $0.role == .user && $0.plainText == "once" }.count == 1)
        await self.finish(gateway)
    }

    @Test func editAttachmentsGoOutWithTheMessage() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        #expect(chat.beginEdit(user.id))
        let image = OutgoingAttachment(fileName: "a.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let outcome = await chat.sendEdit("with a picture", attachments: [image])
        if case .sent = outcome {} else { Issue.record("Image edit was not accepted: \(outcome)") }
        // Acceptance initially leaves lightweight .file metadata; the authoritative history event
        // supplies the image block. Wait for that actual state rather than racing the optimistic row.
        await self.settle {
            chat.items.last { $0.role == .user && $0.plainText == "with a picture" }?.blocks.contains {
                if case .image = $0 { true } else { false }
            } == true
        }
        let sent = chat.items.last { $0.role == .user && $0.plainText == "with a picture" }
        #expect(sent?.blocks.contains { if case .image = $0 { true } else { false } } == true)
        await self.finish(gateway)
    }

    private func imageCount(_ item: ChatItem?) -> Int {
        item?.blocks.filter { if case .image = $0 { true } else { false } }.count ?? 0
    }

    /// #397: sessions.rewind's editorAttachments go out again with the edit.
    @Test func editResendsTheRewoundMessagesImage() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        #expect(self.imageCount(user) == 1, "the seeded message carries an image")
        #expect(chat.beginEdit(user.id))
        _ = await chat.sendEdit("shade, with the photo", attachments: [])
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant }
        await chat.load(force: true)
        let sent = chat.items.last { $0.role == .user && $0.plainText == "shade, with the photo" }
        #expect(self.imageCount(sent) == 1)
        await self.finish(gateway)
    }

    @Test func regenerateResendsTheRewoundMessagesImage() async {
        let gateway = await self.connected()
        let (chat, _) = await self.editableFork(gateway)
        let reply = self.messages(chat, .assistant).last!
        #expect(await chat.regenerate(reply.id))
        await self.settle { !chat.isRunning && chat.items.last?.role == .assistant && chat.items.last?.id != reply.id }
        await chat.load(force: true)
        #expect(self.imageCount(self.messages(chat, .user).last) == 1)
        await self.finish(gateway)
    }

    @Test func branchFromAnImageMessageKeepsItsTextForTheComposer() async {
        let gateway = await self.connected()
        let source = await self.loaded(gateway, Self.garden)
        let user = self.messages(source, .user).last!
        let key = await source.branch(from: user.id)
        let fork = await self.loaded(gateway, key ?? "")
        #expect(fork.draft.text == user.plainText)
        await self.finish(gateway)
    }

    @Test func regenerateLeavesEditMode() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        #expect(chat.beginEdit(user.id))
        let reply = self.messages(chat, .assistant).last!
        #expect(chat.canRegenerate(reply.id))
        #expect(await chat.regenerate(reply.id))
        #expect(chat.editTarget == nil)
        await self.finish(gateway)
    }

    @Test func nothingIsOfferedWhileARunStreams() async {
        let gateway = await self.connected()
        let (chat, user) = await self.editableFork(gateway)
        chat.isRunning = true
        let reply = self.messages(chat, .assistant).last!
        #expect(!chat.canEdit(user.id) && !chat.canRegenerate(reply.id) && !chat.canBranch(from: user.id) && !chat.canSwitchBranches)
        chat.isRunning = false
        await self.finish(gateway)
    }
}
