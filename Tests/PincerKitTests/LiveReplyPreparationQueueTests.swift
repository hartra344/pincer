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
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 512,
                                              normalizer: { gate.normalize($0) })
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
        #expect(queue.submit(self.input(owner: owner, generation: 1, sequence: 4, id: "overflow",
                                        text: "Never queued.")) { completed.append($0, $1) } == .rejectedPendingCount)
        #expect(queue.pendingCount == 2, "overflow leaves earlier queued work intact")
        #expect(gate.mainThreadFlags == [false], "the blocked normalizer is already off-main")

        gate.releaseBlockedWork()
        let drained = await eventually {
            queue.isIdle && completed.values.map(\.0.sequence) == [1, 2, 3]
        }
        #expect(drained)
        #expect(completed.values.map(\.0.sequence) == [1, 2, 3])
        #expect(completed.values.map(\.1) == [true, false, true],
                "a later code-only message doesn't erase an earlier speakable candidate")
        #expect(gate.mainThreadFlags == [false, false, false], "every admitted normalization ran off-main")
    }

    @Test func invalidatedPendingWorkIsDroppedButTheActiveSlotWaitsForWorkerExit() async {
        let owner = UUID()
        let activeID = "live-reply-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 512,
                                              normalizer: { gate.normalize($0) })
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

    @Test func inputAndRetainedByteBudgetsRejectWithoutStartingMoreWork() async {
        let owner = UUID()
        let activeID = "live-reply-byte-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let active = self.input(owner: owner, generation: 1, sequence: 1, id: activeID, text: "abc")
        let pending = self.input(owner: owner, generation: 1, sequence: 2, id: "pending", text: "de")
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 4,
                                              retainedByteLimit: active.retainedBytes + pending.retainedBytes,
                                              normalizer: { gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        #expect(queue.submit(active) { completed.append($0, $1) } == .started)
        #expect(await gate.waitUntilEntered())

        #expect(queue.submit(pending) { completed.append($0, $1) } == .queued)
        let overBudget = self.input(owner: owner, generation: 1, sequence: 3, id: "too-many-bytes", text: "fghij")
        #expect(queue.submit(overBudget) { completed.append($0, $1) } == .rejectedPendingBytes)
        let singleTooLarge = self.input(owner: owner, generation: 1, sequence: 4, id: "too-large-message",
                                        text: String(repeating: "x", count: LiveReplyPreparationQueue.messageTextByteLimit + 1))
        #expect(queue.submit(singleTooLarge) { completed.append($0, $1) } == .rejectedPendingBytes)
        #expect(queue.pendingCount == 1 && queue.pendingBytes == pending.retainedBytes)
        #expect(gate.startedIDs == [activeID], "rejected inputs don't reach the worker")

        gate.releaseBlockedWork()
        let drained = await eventually { queue.isIdle && completed.values.count == 2 }
        #expect(drained)
        #expect(completed.values.map(\.0.itemID) == [activeID, "pending"])
    }

    @Test func replacingPendingWorkKeepsItsFIFOPositionAndUsesLatestSnapshot() async {
        let owner = UUID()
        let activeID = "replace-pending-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 2_048,
                                              normalizer: { gate.normalize($0) })
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
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { gate.normalize($0) })
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
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { gate.normalize($0) })
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
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { gate.normalize($0) })
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
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 2_048,
                                              normalizer: { gate.normalize($0) })
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
