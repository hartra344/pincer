import Foundation
import Synchronization
import Testing
@testable import PincerKit

@MainActor
@Suite("Live reply preparation flow", .serialized)
struct LiveReplyPreparationFlowTests {
    private let profile = GatewayProfile(name: "Live reply tests", url: "ws://127.0.0.1:1", authMode: .none)
    private let sessionKey = "agent:research:main"

    @Test func finalWaitsForEarlierPreparationsAndSelectsLastSpeakableReply() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = LiveReplyPreparationNormalizerGate()
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        let firstID = "first-\(UUID().uuidString)"
        gate.block(firstID)
        self.sendAssistant(chat, id: firstID, blocks: ["First answer."])
        #expect(chat.items.contains { $0.id == firstID }, "transcript delivery is committed before normalization finishes")
        #expect(await gate.waitUntilEntered())

        self.sendAssistant(chat, id: "code-only", blocks: ["```swift\nlet answer = 42\n```"])
        self.sendAssistant(chat, id: "last-answer", blocks: ["The later answer."])
        self.finish(chat, runID: "run-with-queued-replies")
        #expect(chat.liveReplyPreparationQueue.activeCount == 1 && chat.liveReplyPreparationQueue.pendingCount == 2)
        #expect(recorder.items.isEmpty, "success waits for all already accepted reply preparations")

        gate.releaseBlockedWork()
        let delivered = await eventually {
            chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1
        }
        #expect(delivered)
        #expect(recorder.items.map(\.id) == ["last-answer"],
                "FIFO preparation retains the latest speakable reply across a code-only message")
    }

    @Test func latestAcceptedSameIDUpdateWinsOverInterveningReply() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let updatingID = "live-same-id-update-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [updatingID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: updatingID, blocks: ["The original A text."])
        #expect(await gate.waitUntilEntered())
        self.sendAssistant(chat, id: "intervening-B", blocks: ["B arrived after A."])
        self.sendAssistant(chat, id: updatingID, blocks: ["A was updated after B."])
        self.finish(chat, runID: "same-id-update-run")
        gate.releaseBlockedWork()

        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [updatingID])
        #expect(recorder.items.first?.plainText == "A was updated after B.",
                "latest accepted-event sequence wins even though A retains its original queue position")
    }

    @Test func sameIDUpdateAfterSuccessfulFinalStaysInsideExistingBarrier() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let updatingID = "post-final-same-id-update-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [updatingID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: updatingID, blocks: ["The original A text."])
        #expect(await gate.waitUntilEntered())
        self.finish(chat, runID: "post-final-same-id-update-run")
        #expect(chat.liveReplyFinalBarrierRemaining == 1,
                "successful completion snapshots A as outstanding before its same-ID update")

        self.sendAssistant(chat, id: updatingID, blocks: ["A was updated after successful final."])
        #expect(chat.items.first { $0.id == updatingID }?.plainText == "A was updated after successful final.")
        gate.releaseBlockedWork()

        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [updatingID])
        #expect(recorder.items.first?.plainText == "A was updated after successful final.",
                "the existing barrier waits for the latest accepted revision of its outstanding queue item")
        #expect(chat.liveReplyFinalBarrierSequence == nil && chat.liveReplyFinalBarrierRemaining == 0,
                "completion of the replaced worker membership must drain, not strand, the barrier")
    }

    @Test func newReplyAcceptedAfterSuccessDoesNotExtendExistingBarrier() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let heldID = "pre-final-held-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [heldID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: heldID, blocks: ["A belongs to the successful run."])
        #expect(await gate.waitUntilEntered())
        self.finish(chat, runID: "post-final-new-reply-run")
        self.sendAssistant(chat, id: "after-final-B", blocks: ["B arrived after the final event."])
        #expect(chat.liveReplyPreparationQueue.activeCount == 1 && chat.liveReplyPreparationQueue.pendingCount == 1,
                "B is queued after the barrier snapshot while A remains held")

        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [heldID],
                "the terminal barrier delivers its pre-success A member, not ordinary post-success B")
        #expect(recorder.items.first?.plainText == "A belongs to the successful run.")
        #expect(chat.liveReplyFinalBarrierSequence == nil && chat.liveReplyFinalBarrierRemaining == 0)
    }

    @Test func cappedReplyRecoveryReplacesHeldPreparationWithFullProse() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let messageID = "capped-held-prose-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [messageID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: messageID, blocks: ["Capped preview that must not be spoken."], capped: true)
        #expect(chat.items.first?.isCapped == true, "the actual accepted-event fixture carries truncated metadata")
        #expect(await gate.waitUntilEntered())
        let full = ChatItem(self.payload(role: "assistant", id: messageID,
                                         blocks: ["The complete restored prose is the eligible reply."]), fallbackIndex: 0)!
        chat.fullMessages[messageID] = full
        chat.recoverCappedMessages()
        #expect(chat.items.first?.plainText == "The complete restored prose is the eligible reply.")

        self.finish(chat, runID: "capped-held-prose-run")
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [messageID])
        #expect(recorder.items.first?.plainText == "The complete restored prose is the eligible reply.",
                "the outstanding preparation follows the actual cached full-copy recovery")
        #expect(!recorder.items.contains { $0.plainText.contains("Capped preview") })
        #expect(chat.liveReplyFinalBarrierSequence == nil && chat.liveReplyFinalBarrierRemaining == 0)
    }

    @Test func cappedReplyRecoveryToCodeOnlyCannotPublishOldProse() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let messageID = "capped-held-code-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [messageID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: messageID, blocks: ["Old prose from the capped preview."], capped: true)
        #expect(chat.items.first?.isCapped == true)
        #expect(await gate.waitUntilEntered())
        let full = ChatItem(self.payload(role: "assistant", id: messageID,
                                         blocks: ["```swift\nlet answer = 42\n```"]), fallbackIndex: 0)!
        chat.fullMessages[messageID] = full
        chat.recoverCappedMessages()
        #expect(chat.items.first?.plainText.contains("let answer = 42") == true)

        self.finish(chat, runID: "capped-held-code-run")
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(recorder.items.isEmpty, "stale speakability for the truncated prose cannot survive a code-only restore")
        #expect(chat.liveReplyCandidate == nil && chat.awaitingFinalReply)
    }

    @Test func unrelatedCappedHistoryRestoreCannotReplacePreparedLiveCandidate() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let historicalID = "unrelated-capped-history-\(UUID().uuidString)"
        let liveID = "current-live-candidate-\(UUID().uuidString)"
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue())
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        let cappedHistory = ChatItem(self.payload(role: "assistant", id: historicalID,
                                                   blocks: ["Historical preview."], capped: true), fallbackIndex: 0)!
        chat.items = [cappedHistory]

        self.sendAssistant(chat, id: liveID, blocks: ["The current live run should be read."])
        #expect(await eventually {
            chat.liveReplyPreparationQueue.isIdle && chat.liveReplyCandidate?.id == liveID
        })
        let fullHistory = ChatItem(self.payload(role: "assistant", id: historicalID,
                                                 blocks: ["Unrelated restored historical prose."]), fallbackIndex: 0)!
        chat.fullMessages[historicalID] = fullHistory
        chat.recoverCappedMessages()
        #expect(chat.items.first?.plainText == "Unrelated restored historical prose.")

        self.finish(chat, runID: "candidate-with-history-recovery")
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [liveID],
                "restoring an unrelated capped history row cannot make it eligible or displace the live candidate")
        #expect(recorder.items.first?.plainText == "The current live run should be read.")
    }

    @Test func successfulFinalBeforeMessageDeliversFirstLaterSpeakableReplyOnce() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue())
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.finish(chat, runID: "final-before-message")
        self.finish(chat, runID: "final-before-message")
        self.sendAssistant(chat, id: "late-reply", blocks: ["A reply committed after final."])

        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == ["late-reply"], "duplicate final events don't duplicate delivery")
    }

    @Test func identicalHistoryRefreshKeepsPreparedCandidateUntilSuccess() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue())
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        let preparedID = "already-prepared-before-refresh"
        let preparedRaw = self.payload(role: "assistant", id: preparedID, blocks: ["Earlier eligible answer."])
        self.sendAssistant(chat, id: preparedID, blocks: ["Earlier eligible answer."])
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && chat.liveReplyCandidate?.id == preparedID })

        let parsed = ChatStore.parse([preparedRaw])
        chat.apply(history: ["messages": .array([preparedRaw])], parsed: parsed)
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && chat.liveReplyCandidate?.id == preparedID },
                "an identical history refresh preserves or revalidates the prepared candidate")

        self.finish(chat, runID: "identical-history-refresh")
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [preparedID], "the unchanged prepared candidate is delivered once")
    }

    @Test func identicalHistoryRefreshPreservesHeldNewerReplyOrdering() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let heldID = "held-identical-refresh-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [heldID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        let preparedID = "prior-candidate-before-held-refresh"
        let preparedRaw = self.payload(role: "assistant", id: preparedID, blocks: ["Earlier eligible answer."])
        self.sendAssistant(chat, id: preparedID, blocks: ["Earlier eligible answer."])
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && chat.liveReplyCandidate?.id == preparedID })

        let heldRaw = self.payload(role: "assistant", id: heldID, blocks: ["Newest answer still being prepared."])
        self.sendAssistant(chat, id: heldID, blocks: ["Newest answer still being prepared."])
        #expect(await gate.waitUntilEntered())
        let parsed = ChatStore.parse([preparedRaw, heldRaw])
        chat.apply(history: ["messages": .array([preparedRaw, heldRaw])], parsed: parsed)
        #expect(chat.liveReplyPreparationQueue.activeCount == 1,
                "an identical refresh leaves the in-flight newer message eligible")
        #expect(recorder.items.isEmpty, "history refresh does not publish a reply before successful completion")

        self.finish(chat, runID: "identical-history-refresh")
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == [heldID],
                "after an identical refresh the successful barrier delivers the newest speakable reply once")
    }

    @Test func staleSameIDPreparationCannotSpeakAfterAuthoritativeHistoryReplacement() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let staleID = "same-id-history-edit-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [staleID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: staleID, blocks: ["This old prose must not be spoken."])
        #expect(await gate.waitUntilEntered())
        let authoritative = self.payload(role: "assistant", id: staleID, blocks: ["```swift\nlet x = 1\n```"])
        let parsed = ChatStore.parse([authoritative])
        chat.apply(history: ["messages": .array([authoritative])], parsed: parsed)
        #expect(chat.items.first { $0.id == staleID }?.plainText.contains("let x = 1") == true,
                "the authoritative history replacement is installed while the old worker is held")

        self.finish(chat, runID: "history-replaced-reply")
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(recorder.items.isEmpty,
                "a speakability result for replaced prose cannot select same-ID code-only history")
        #expect(chat.awaitingFinalReply,
                "the successful run remains ready for a later speakable message after stale work is discarded")

        self.sendAssistant(chat, id: "unrelated-valid-reply", blocks: ["A current answer remains eligible."])
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == ["unrelated-valid-reply"],
                "the empty successful barrier speaks later fresh prose exactly once, not the stale replacement")
        #expect(!chat.awaitingFinalReply)
    }

    @Test func callbackRemovalInvalidatesHeldPreparation() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let heldID = "removed-callback-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [heldID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: heldID, blocks: ["Prepared while a window is visible."])
        #expect(await gate.waitUntilEntered())
        chat.onFinalAssistantReply = nil
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(recorder.items.isEmpty && chat.liveReplyCandidate == nil)

        chat.onFinalAssistantReply = { recorder.items.append($0) }
        chat.handleChat(["runId": "after-reinstall", "sessionKey": .string(self.sessionKey), "state": "status", "phase": "thinking"])
        self.sendAssistant(chat, id: "fresh-after-reinstall", blocks: ["Fresh reply."])
        self.finish(chat, runID: "after-reinstall")
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle && recorder.items.count == 1 })
        #expect(recorder.items.map(\.id) == ["fresh-after-reinstall"])
    }

    @Test func replacingCallbackDoesNotTransferHeldReplyToNewHandler() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let heldID = "callback-replaced-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [heldID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let previousHandler = ReplyRecorder()
        let replacementHandler = ReplyRecorder()
        chat.onFinalAssistantReply = { previousHandler.items.append($0) }

        self.sendAssistant(chat, id: heldID, blocks: ["This pending answer belongs to the prior handler."])
        #expect(await gate.waitUntilEntered())
        self.finish(chat, runID: "callback-replacement-run")
        chat.onFinalAssistantReply = { replacementHandler.items.append($0) }
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(previousHandler.items.isEmpty && replacementHandler.items.isEmpty,
                "a new nonnil handler does not inherit work accepted by the previous handler")

        chat.handleSessionMessage(["message": self.payload(role: "user", id: "fresh-user-turn", blocks: ["New question."])])
        chat.handleChat(["runId": "fresh-after-handler-change", "sessionKey": .string(self.sessionKey),
                         "state": "status", "phase": "thinking"])
        self.sendAssistant(chat, id: "fresh-handler-reply", blocks: ["This answer belongs to the replacement."])
        self.finish(chat, runID: "fresh-after-handler-change")
        #expect(await eventually {
            chat.liveReplyPreparationQueue.isIdle && replacementHandler.items.count == 1
        })
        #expect(previousHandler.items.isEmpty && replacementHandler.items.map(\.id) == ["fresh-handler-reply"])
    }

    @Test func userMessageAndFailedRunDropHeldPreparations() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let userInterruptedID = "user-interrupted-\(UUID().uuidString)"
        let failedID = "failed-run-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [userInterruptedID, failedID])
        defer { gate.releaseBlockedWork() }
        let chat = self.makeChat(defaults: scratch.defaults, queue: LiveReplyPreparationQueue(
            normalizer: { gate.normalize($0) }))
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }

        self.sendAssistant(chat, id: userInterruptedID, blocks: ["Superseded by the next user turn."])
        #expect(await gate.waitUntilEntered())
        chat.handleSessionMessage(["message": self.payload(role: "user", id: "new-user-turn", blocks: ["A new question."])])
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(recorder.items.isEmpty && chat.liveReplyCandidate == nil)

        chat.handleChat(["runId": "failed-run", "sessionKey": .string(self.sessionKey), "state": "status", "phase": "thinking"])
        gate.block(failedID)
        self.sendAssistant(chat, id: failedID, blocks: ["This run will fail."])
        #expect(await gate.waitUntilEntered())
        self.finish(chat, runID: "failed-run", state: "error")
        gate.releaseBlockedWork()
        #expect(await eventually { chat.liveReplyPreparationQueue.isIdle })
        #expect(recorder.items.isEmpty && chat.liveReplyCandidate == nil,
                "a user turn or failed run invalidates held speech work")
    }

    @Test func manyChatsAllDeliverTheirFinalReplyWithoutSuppression() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let heldChatKey = "agent:held:main"
        let heldID = "many-chats-held-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [heldID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let gateway = GatewayStore(profile: self.profile, defaults: scratch.defaults, identity: Fixtures.identity())
        let recorder = ReplyRecorder()

        func attach(_ key: String) -> ChatStore {
            let chat = gateway.chat(for: key)
            chat.liveReplyPreparationQueue = queue
            chat.onFinalAssistantReply = { recorder.items.append($0) }
            return chat
        }
        func send(_ chat: ChatStore, id: String, text: String) {
            chat.handleSessionMessage(["message": self.payload(role: "assistant", id: id, blocks: [text])])
        }
        func finish(_ chat: ChatStore, key: String, run: String) {
            chat.handleChat(["runId": .string(run), "sessionKey": .string(key), "state": "final"])
        }

        let held = attach(heldChatKey)
        send(held, id: heldID, text: "The held reply.")
        #expect(await gate.waitUntilEntered())

        let count = 40
        let keys = (0..<count).map { "agent:chat\($0):main" }
        let chats = keys.map { attach($0) }
        for (index, chat) in chats.enumerated() {
            send(chat, id: "reply-\(index)", text: "Reply number \(index).")
            #expect(!chat.liveReplyGenerationSuppressed, "chat \(index) isn't suppressed by other chats' queued work")
            finish(chat, key: keys[index], run: "run-\(index)")
        }
        finish(held, key: heldChatKey, run: "held-run")
        #expect(queue.pendingCount == count)

        gate.releaseBlockedWork()
        #expect(await eventually(timeout: .seconds(10)) { queue.isIdle && recorder.items.count == count + 1 })
        let delivered = recorder.items.map(\.id)
        #expect(Set(delivered) == Set((0..<count).map { "reply-\($0)" } + [heldID]))
        #expect(delivered.count == Set(delivered).count, "every final reply is delivered exactly once")
        #expect(chats.allSatisfy { !$0.liveReplyGenerationSuppressed } && !held.liveReplyGenerationSuppressed)
    }

    @Test func withoutFinalReplyCallbackTheQueueIsNeverTouched() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let normalized = Mutex<Int>(0)
        let queue = LiveReplyPreparationQueue(normalizer: { _ in normalized.withLock { $0 += 1 }; return true })
        let chat = self.makeChat(defaults: scratch.defaults, queue: queue)
        #expect(chat.onFinalAssistantReply == nil)

        self.sendAssistant(chat, id: "no-callback", blocks: ["A reply nobody will speak."])
        self.finish(chat, runID: "no-callback-run")
        #expect(chat.items.contains { $0.id == "no-callback" })
        #expect(queue.isIdle && queue.retainedByteCount == 0)
        for _ in 0..<5 { await Task.yield() }
        #expect(normalized.withLock { $0 } == 0, "the normalizer never runs without an opted-in callback")
    }

    @Test func oversizedInputSuppressesReadAloudWithoutDroppingAcceptedMessage() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let queue = LiveReplyPreparationQueue()
        let chat = self.makeChat(defaults: scratch.defaults, queue: queue)
        let recorder = ReplyRecorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        let text = String(repeating: "a", count: LiveReplyPreparationQueue.messageTextByteLimit + 1)

        self.sendAssistant(chat, id: "oversized-text", blocks: [text])
        #expect(chat.items.contains { $0.id == "oversized-text" }, "oversize speech input still commits to the transcript")
        #expect(chat.liveReplyGenerationSuppressed && queue.isIdle,
                "oversized input is suppressed before it enters the normalization queue")
        self.finish(chat, runID: "oversized-run")
        #expect(recorder.items.isEmpty)

        chat.handleChat(["runId": "new-run", "sessionKey": .string(self.sessionKey), "state": "status", "phase": "thinking"])
        let manyBlocks = (0 ..< 65).map { "part \($0)" }
        self.sendAssistant(chat, id: "too-many-blocks", blocks: manyBlocks)
        #expect(chat.items.contains { $0.id == "too-many-blocks" })
        #expect(chat.liveReplyGenerationSuppressed && queue.isIdle,
                "more than 64 text blocks suppresses only preparation work")
    }

    private func makeChat(defaults: UserDefaults, queue: LiveReplyPreparationQueue) -> ChatStore {
        let gateway = GatewayStore(profile: self.profile, defaults: defaults, identity: Fixtures.identity())
        let chat = gateway.chat(for: self.sessionKey)
        chat.liveReplyPreparationQueue = queue
        return chat
    }

    private func sendAssistant(_ chat: ChatStore, id: String, blocks: [String], capped: Bool = false) {
        chat.handleSessionMessage(["message": self.payload(role: "assistant", id: id, blocks: blocks, capped: capped)])
    }

    private func finish(_ chat: ChatStore, runID: String, state: String = "final") {
        chat.handleChat(["runId": .string(runID), "sessionKey": .string(self.sessionKey), "state": .string(state)])
    }

    private func payload(role: String, id: String, blocks: [String], capped: Bool = false) -> JSONValue {
        let content = blocks.map { JSONValue.object(["type": .string("text"), "text": .string($0)]) }
        var openclaw: [String: JSONValue] = ["id": .string(id)]
        if capped { openclaw["truncated"] = .bool(true) }
        return ["role": .string(role), "content": .array(content), "__openclaw": .object(openclaw)]
    }

    @MainActor
    private final class ReplyRecorder {
        var items: [ChatItem] = []
    }
}

private final class LiveReplyPreparationNormalizerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedIDs: Set<String>
    private var didRelease = false
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(blockedIDs: Set<String> = []) { self.blockedIDs = blockedIDs }

    func block(_ id: String) {
        self.lock.withLock {
            self.blockedIDs.insert(id)
            self.didRelease = false
        }
    }

    func normalize(_ input: LiveReplyPreparationInput) -> Bool {
        let shouldBlock = self.lock.withLock { self.blockedIDs.remove(input.itemID) != nil }
        if shouldBlock {
            self.entered.signal()
            self.waitSynchronouslyForRelease()
        }
        return SpeechText.isSpeakable(textBlocks: input.textBlocks, itemID: input.itemID)
    }

    func waitUntilEntered() async -> Bool {
        await Task.detached(priority: .utility) { self.waitSynchronouslyUntilEntered() }.value
    }

    private func waitSynchronouslyUntilEntered() -> Bool {
        self.entered.wait(timeout: .now() + 3) == .success
    }

    private func waitSynchronouslyForRelease() {
        self.release.wait()
    }

    func releaseBlockedWork() {
        let shouldSignal = self.lock.withLock { () -> Bool in
            guard !self.didRelease else { return false }
            self.didRelease = true
            return true
        }
        if shouldSignal { self.release.signal() }
    }
}
