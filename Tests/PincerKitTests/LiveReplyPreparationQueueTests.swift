import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Live reply preparation queue", .serialized)
struct LiveReplyPreparationQueueTests {
    @Test func queuedTextIsNormalizedOffMainAndDrainsInArrivalOrder() async {
        let owner = UUID()
        let blockedID = "live-reply-first-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [blockedID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let first = self.input(owner: owner, generation: 1, sequence: 1, id: blockedID,
                               text: "First spoken reply.")
        let codeOnly = self.input(owner: owner, generation: 1, sequence: 2, id: "live-reply-code-only",
                                  text: "```swift\nlet value = 42\n```")
        let last = self.input(owner: owner, generation: 1, sequence: 3, id: "live-reply-last",
                              text: "Last spoken reply.")

        #expect(queue.submit(first) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.submit(codeOnly) { completed.append($0, $1) } == .queued)
        #expect(queue.submit(last) { completed.append($0, $1) } == .queued)
        #expect(queue.activeCount == 1 && queue.pendingCount == 2)
        #expect(queue.submit(self.input(owner: owner, generation: 1, sequence: 4, id: "fourth",
                                        text: "Fourth reply.")) { completed.append($0, $1) } == .queued,
                "there is no global pending count limit")
        #expect(queue.pendingCount == 3)
        #expect(gate.mainThreadFlags == [false], "the blocked normalizer is already off-main")

        gate.releaseBlockedWork()
        let drained = await eventually {
            queue.isIdle && completed.values.map(\.0.sequence) == [1, 2, 3, 4]
        }
        #expect(drained)
        #expect(completed.values.map(\.0.sequence) == [1, 2, 3, 4])
        #expect(completed.values.map(\.1) == [true, false, true, true],
                "a later code-only message doesn't erase an earlier speakable candidate")
        #expect(gate.mainThreadFlags == [false, false, false, false], "every admitted normalization ran off-main")
    }

    @Test func invalidatedPendingWorkIsDroppedButTheActiveSlotWaitsForWorkerExit() async {
        let owner = UUID()
        let activeID = "live-reply-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let active = self.input(owner: owner, generation: 8, sequence: 1, id: activeID, text: "Active.")
        let obsolete = self.input(owner: owner, generation: 8, sequence: 2, id: "obsolete", text: "Old pending.")
        #expect(queue.submit(active) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.submit(obsolete) { completed.append($0, $1) } == .queued)

        queue.cancelPending(ownerID: owner, generation: 8)
        #expect(queue.activeCount == 1 && queue.pendingCount == 0)
        #expect(queue.retainedByteCount == active.retainedBytes,
                "dropping pending work releases its budget but does not free a still-running worker")

        let replacement = self.input(owner: owner, generation: 9, sequence: 3, id: "replacement", text: "New run.")
        #expect(queue.submit(replacement) { completed.append($0, $1) } == .queued,
                "new-generation work waits behind the active normalizer")
        #expect(gate.startedIDs == [activeID], "the replacement never overlaps the held worker")

        gate.releaseBlockedWork()
        let drained = await eventually {
            queue.isIdle && completed.values.map(\.0.itemID) == [activeID, "replacement"]
        }
        #expect(drained)
        #expect(completed.values.map(\.0.itemID) == [activeID, "replacement"],
                "canceled pending work has no completion and the active slot is reused only after exit")
    }

    @Test func manyOwnersAreAllQueuedAndCompleteWithoutGlobalRejection() async {
        let activeID = "many-owners-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let first = self.input(owner: UUID(), generation: 1, sequence: 1, id: activeID, text: "Active.")
        #expect(queue.submit(first) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())

        let chats = 40
        for index in 0..<chats {
            let input = self.input(owner: UUID(), generation: 1, sequence: 1, id: "chat-\(index)", text: "Reply \(index).")
            #expect(queue.submit(input) { completed.append($0, $1) } == .queued, "chat \(index) is never rejected")
        }
        #expect(queue.pendingCount == chats)

        gate.releaseBlockedWork()
        #expect(await eventually(timeout: .seconds(10)) { queue.isIdle && completed.values.count == chats + 1 })
        #expect(completed.values.map(\.0.itemID) == [activeID] + (0..<chats).map { "chat-\($0)" })
        #expect(completed.values.allSatisfy { $0.1 })
    }

    @Test func perOwnerByteBudgetStripsOnlyThatOwnersOldestPendingText() async {
        let busy = UUID(), other = UUID()
        let activeID = "per-owner-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        // The queue floors the budget just above one maximum-size message.
        let limit = LiveReplyPreparationQueue.messageTextByteLimit + 1024
        let queue = LiveReplyPreparationQueue(perOwnerByteLimit: limit, normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let big = String(repeating: "word ", count: 20_000)

        #expect(queue.submit(self.input(owner: UUID(), generation: 1, sequence: 1, id: activeID, text: "Active.")) {
            completed.append($0, $1)
        } == .started)
        #expect(await gate.waitUntilEntered())
        let otherInput = self.input(owner: other, generation: 1, sequence: 1, id: "other", text: big)
        #expect(queue.submit(otherInput) { completed.append($0, $1) } == .queued)
        var busyInputs: [LiveReplyPreparationInput] = []
        for (index, id) in ["old-1", "old-2", "old-3"].enumerated() {
            let input = self.input(owner: busy, generation: 1, sequence: UInt64(index + 1), id: id, text: big)
            busyInputs.append(input)
            #expect(queue.submit(input) { completed.append($0, $1) } == .queued)
        }
        #expect(queue.pendingCount == 4, "stripped items stay in the FIFO")
        #expect(queue.pendingBytes == otherInput.retainedBytes + busyInputs[1].retainedBytes + busyInputs[2].retainedBytes,
                "only the busy owner's oldest pending text was released")

        gate.releaseBlockedWork()
        #expect(await eventually { queue.isIdle && completed.values.count == 5 })
        let results = Dictionary(uniqueKeysWithValues: completed.values.map { ($0.0.itemID, $0.1) })
        #expect(results["old-1"] == false, "the oldest pending text is dropped and completes false")
        #expect(results["old-3"] == true, "the newest item is never stripped")
        #expect(results["other"] == true, "other owners are unaffected")
        #expect(!gate.startedIDs.contains("old-1"), "stripped text never reaches the normalizer")
        #expect(completed.values.map(\.0.itemID) == [activeID, "other", "old-1", "old-2", "old-3"])
    }

    @Test func oversizedSingleMessageIsStillRejected() async {
        let queue = LiveReplyPreparationQueue()
        let tooLarge = self.input(owner: UUID(), generation: 1, sequence: 1, id: "too-large-message",
                                  text: String(repeating: "x", count: LiveReplyPreparationQueue.messageTextByteLimit + 1))
        #expect(queue.submit(tooLarge) { _, _ in } == .rejectedPendingBytes)
        #expect(!queue.replace(tooLarge))
        #expect(queue.isIdle)
        #expect(LiveReplyPreparationQueue.perOwnerByteLimit >= 2 * LiveReplyPreparationQueue.messageTextByteLimit)
    }

    @Test func replacingPendingWorkKeepsItsFIFOPositionAndUsesLatestSnapshot() async {
        let owner = UUID()
        let activeID = "replace-pending-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let active = self.input(owner: owner, generation: 1, sequence: 1, id: activeID, text: "Active.")
        let pending = self.input(owner: owner, generation: 1, sequence: 2, id: "pending-target", text: "```swift\nlet x = 1\n```")
        let later = self.input(owner: owner, generation: 1, sequence: 3, id: "after-target", text: "Later FIFO reply.")
        let replacement = self.input(owner: owner, generation: 1, sequence: 4, id: "pending-target", text: "Replacement prose.")

        #expect(queue.submit(active) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.submit(pending) { completed.append($0, $1) } == .queued)
        #expect(queue.submit(later) { completed.append($0, $1) } == .queued)
        #expect(queue.replace(replacement))
        #expect(queue.pendingCount == 2, "refresh replaces the pending snapshot without growing the queue")
        #expect(queue.pendingBytes == replacement.retainedBytes + later.retainedBytes)

        gate.releaseBlockedWork()
        #expect(await eventually { queue.isIdle && completed.values.count == 3 })
        #expect(completed.values.map(\.0.itemID) == [activeID, "pending-target", "after-target"])
        #expect(completed.values.map(\.0.sequence) == [1, 4, 3],
                "the latest event token retains the original pending FIFO position")
        #expect(gate.normalizedTexts.map(\.1) == ["Active.", "Replacement prose.", "Later FIFO reply."],
                "the replaced code-only snapshot never reaches normalization")
    }

    @Test func identicalActiveRefreshNormalizesOnceButPublishesLatestToken() async {
        let owner = UUID()
        let activeID = "replace-active-identical-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let original = self.input(owner: owner, generation: 4, sequence: 1, id: activeID, text: "Same source.")
        let refreshed = self.input(owner: owner, generation: 4, sequence: 2, id: activeID, text: "Same source.")

        #expect(queue.submit(original) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.replace(refreshed))
        #expect(queue.activeCount == 1 && queue.retainedByteCount == original.retainedBytes + refreshed.retainedBytes)
        gate.releaseBlockedWork()

        #expect(await eventually { queue.isIdle && completed.values.count == 1 })
        #expect(completed.values.map(\.0.sequence) == [2], "the unchanged result is associated with the latest event token")
        #expect(gate.normalizedTexts.map(\.1) == ["Same source."], "identical text is not normalized twice")
    }

    @Test func repeatedActiveRefreshKeepsOnlyLatestSnapshotAndNoStaleCompletion() async {
        let owner = UUID()
        let activeID = "replace-active-latest-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let original = self.input(owner: owner, generation: 5, sequence: 1, id: activeID, text: "Old source.")
        let intermediate = self.input(owner: owner, generation: 5, sequence: 2, id: activeID, text: "Superseded source.")
        let latest = self.input(owner: owner, generation: 5, sequence: 3, id: activeID, text: "Latest source.")

        #expect(queue.submit(original) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.replace(intermediate))
        #expect(queue.replace(latest))
        #expect(queue.activeCount == 1 && queue.pendingCount == 0)
        #expect(queue.retainedByteCount == original.retainedBytes + latest.retainedBytes,
                "only active and latest replacement snapshots remain charged")
        gate.releaseBlockedWork()

        #expect(await eventually { queue.isIdle && completed.values.count == 1 })
        #expect(completed.values.map(\.0.sequence) == [3], "superseded active results never complete")
        #expect(gate.normalizedTexts.map(\.1) == ["Old source.", "Latest source."],
                "the middle replacement is discarded before a new normalization stage")
    }

    @Test func cancellingActiveReplacementReleasesOnlyReplacementBudget() async {
        let owner = UUID()
        let generation: UInt64 = 6
        let activeID = "cancel-active-replacement-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let active = self.input(owner: owner, generation: generation, sequence: 1, id: activeID, text: "Active.")
        let replacement = self.input(owner: owner, generation: generation, sequence: 2, id: activeID, text: "Canceled replacement.")
        let next = self.input(owner: owner, generation: generation + 1, sequence: 1, id: "next", text: "Next run.")

        #expect(queue.submit(active) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.replace(replacement))
        queue.cancelPending(ownerID: owner, generation: generation)
        #expect(queue.activeCount == 1 && queue.pendingCount == 0)
        #expect(queue.retainedByteCount == active.retainedBytes,
                "canceling replacement releases its snapshot but retains the running active slot")
        #expect(queue.submit(next) { completed.append($0, $1) } == .queued)
        #expect(gate.startedIDs == [activeID])

        gate.releaseBlockedWork()
        #expect(await eventually { queue.isIdle && completed.values.count == 2 })
        #expect(completed.values.map(\.0.itemID) == [activeID, "next"])
        #expect(gate.normalizedTexts.map(\.1) == ["Active.", "Next run."],
                "the canceled replacement never reaches the normalizer")
    }

    @Test func candidateRevalidationReturnsToItsOriginalFIFOOrder() async {
        let owner = UUID()
        let activeID = "revalidate-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let candidate = self.input(owner: owner, generation: 7, sequence: 1, id: "old-candidate", text: "Original candidate.")
        #expect(queue.submit(candidate) { completed.append($0, $1) } == .started)
        #expect(await eventually { queue.isIdle && completed.values.count == 1 })
        let candidateOrder = completed.values[0].0.queueOrder

        let active = self.input(owner: owner, generation: 7, sequence: 2, id: activeID, text: "Active.")
        let later = self.input(owner: owner, generation: 7, sequence: 3, id: "later", text: "Later queued item.")
        #expect(queue.submit(active) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())
        #expect(queue.submit(later) { completed.append($0, $1) } == .queued)

        let refreshed = self.input(owner: owner, generation: 7, sequence: 4, id: "old-candidate", text: "Refreshed candidate.")
        #expect(queue.submitRevalidation(refreshed, queueOrder: candidateOrder) { completed.append($0, $1) } == .queued)
        #expect(queue.pendingCount == 2)
        gate.releaseBlockedWork()

        #expect(await eventually { queue.isIdle && completed.values.count == 4 })
        #expect(completed.values.map(\.0.queueOrder) == [candidateOrder, candidateOrder + 1, candidateOrder, candidateOrder + 2],
                "candidate revalidation is inserted at its original queue order")
        #expect(gate.normalizedTexts.map(\.1) == ["Original candidate.", "Active.", "Refreshed candidate.", "Later queued item."])
    }

    private func input(owner: UUID, generation: UInt64, sequence: UInt64, revision: UInt64? = nil, id: String, text: String)
        -> LiveReplyPreparationInput
    {
        let textByteCount = text.utf8.count
        let locatorBytes = id.utf8.count * 2
        return LiveReplyPreparationInput(ownerID: owner, generation: generation, sequence: sequence,
                                  revision: revision ?? sequence, itemID: id,
                                  transcriptID: id, fallbackIndex: Int(sequence), textBlocks: [text],
                                  textByteCount: textByteCount, retainedBytes: textByteCount + locatorBytes)
    }

    @MainActor
    private final class LiveReplyCompletionRecorder {
        var values: [(LiveReplyPreparationToken, Bool)] = []
        func append(_ token: LiveReplyPreparationToken, _ speakable: Bool) {
            self.values.append((token, speakable))
        }
    }
}

private final class LiveReplyPreparationNormalizerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedIDs: Set<String>
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var started: [String] = []
    private var normalizedText: [(String, String)] = []
    private var onMain: [Bool] = []
    private var didRelease = false

    init(blockedIDs: Set<String>) { self.blockedIDs = blockedIDs }

    var startedIDs: [String] { self.lock.withLock { self.started } }
    var normalizedTexts: [(String, String)] { self.lock.withLock { self.normalizedText } }
    var mainThreadFlags: [Bool] { self.lock.withLock { self.onMain } }

    func normalize(_ input: LiveReplyPreparationInput) -> Bool {
        let shouldBlock = self.lock.withLock { () -> Bool in
            self.started.append(input.itemID)
            self.normalizedText.append((input.itemID, input.textBlocks.joined(separator: "\n\n")))
            self.onMain.append(Thread.isMainThread)
            return self.blockedIDs.remove(input.itemID) != nil
        }
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
