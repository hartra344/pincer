import Foundation
import Testing
#if os(macOS)
import Darwin
#endif
@testable import PincerKit

@MainActor
@Suite("Live reply preparation queue", .serialized)
struct LiveReplyPreparationQueueTests {
#if DEBUG
    @Test func queuedTextIsNormalizedOffMainAndDrainsInArrivalOrder() async {
        let owner = UUID()
        let blockedID = "live-reply-first-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [blockedID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 512,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func invalidatedPendingWorkIsDroppedButTheActiveSlotWaitsForWorkerExit() async {
        let owner = UUID()
        let activeID = "live-reply-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 512,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func inputAndRetainedByteBudgetsRejectWithoutStartingMoreWork() async {
        let owner = UUID()
        let activeID = "live-reply-byte-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let active = self.input(owner: owner, generation: 1, sequence: 1, id: activeID, text: "abc")
        let pending = self.input(owner: owner, generation: 1, sequence: 2, id: "pending", text: "de")
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 4,
                                              retainedByteLimit: active.retainedBytes + pending.retainedBytes,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func replacingPendingWorkKeepsItsFIFOPositionAndUsesLatestSnapshot() async {
        let owner = UUID()
        let activeID = "replace-pending-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func identicalActiveRefreshNormalizesOnceButPublishesLatestToken() async {
        let owner = UUID()
        let activeID = "replace-active-identical-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func repeatedActiveRefreshKeepsOnlyLatestSnapshotAndNoStaleCompletion() async {
        let owner = UUID()
        let activeID = "replace-active-latest-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func cancellingActiveReplacementReleasesOnlyReplacementBudget() async {
        let owner = UUID()
        let generation: UInt64 = 6
        let activeID = "cancel-active-replacement-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 2, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
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
#endif

#if DEBUG
    @Test func candidateRevalidationReturnsToItsOriginalFIFOOrder() async throws {
        _ = try await candidateRevalidationFixture()
    }

    private func candidateRevalidationFixture() async throws -> Bool {
        let owner = UUID()
        let activeID = "revalidate-active-\(UUID().uuidString)"
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [activeID])
        defer { gate.releaseBlockedWork() }
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let candidate = self.input(owner: owner, generation: 7, sequence: 1, id: "old-candidate", text: "Original candidate.")
        let candidateOrder = try await initialCandidateOrder(candidate, queue: queue, completed: completed)

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
        return queue.isIdle && completed.values.map(\.0.queueOrder) == [candidateOrder, candidateOrder + 1, candidateOrder, candidateOrder + 2]
            && gate.normalizedTexts.map(\.1) == ["Original candidate.", "Active.", "Refreshed candidate.", "Later queued item."]
    }
#endif

    #if DEBUG
    /// Neutral shared boundary: the original readiness expectation is followed by the
    /// original unchecked index. The child observes actual state without changing it.
    @inline(never) private func initialCandidateOrder(
        _ candidate: LiveReplyPreparationInput, queue: LiveReplyPreparationQueue,
        completed: LiveReplyCompletionRecorder,
        afterSubmit: (@MainActor () async throws -> Void)? = nil,
        beforeIndex: (@MainActor (Bool) async throws -> Void)? = nil
    ) async throws -> UInt64 {
        #expect(queue.submit(candidate) { completed.append($0, $1) } == .started)
        try await afterSubmit?()
        let ready = await eventually { queue.isIdle && completed.values.count == 1 }
        #expect(ready, "original candidate readiness before queue-order index")
        try await beforeIndex?(ready)
        return completed.values[0].0.queueOrder
    }
    #endif

    #if DEBUG && os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_LIVE_CANDIDATE_CHILD"] != nil),
          .timeLimit(.minutes(2)))
    func actualCandidateReadinessChild() async throws {
        let mode = ProcessInfo.processInfo.environment["PINCER_LIVE_CANDIDATE_CHILD"]
        try #require(mode == "ordinary" || mode == "held")
        var core = rlimit(rlim_cur: 0, rlim_max: 0)
        let coreResult = Darwin.setrlimit(RLIMIT_CORE, &core)
        try #require(coreResult == 0)
        print("PINCER_LIVE_CANDIDATE_CHILD_PID=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        defer { print("PINCER_LIVE_CANDIDATE_CHILD_COMPLETE=\(mode ?? "")"); fflush(stdout) }
        let owner = UUID()
        let id = "candidate-readiness-" + UUID().uuidString
        let text = "Actual candidate speaks this ordinary sentence."
        let candidate = input(owner: owner, generation: 7, sequence: 1, id: id, text: text)
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: mode == "held" ? [id] : [])
        let queue = LiveReplyPreparationQueue(pendingItemLimit: 3, retainedByteLimit: 2_048,
                                              normalizer: { await gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        var actualTask: Task<Void, Never>?
        let safetyState = LiveCandidateSafety()
        let safetyAction: @Sendable () -> Void = {
            safetyState.expire()
            gate.releaseBlockedWork()
        }
        let safety = DispatchWorkItem(block: safetyAction)
        if mode == "held" { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: safety) }
        defer { safety.cancel(); gate.releaseBlockedWork() }
        var held = false
        let order = try await initialCandidateOrder(candidate, queue: queue, completed: completed,
            afterSubmit: {
                actualTask = queue.actualPreparationTaskForTesting
                if mode == "held" {
                    let entered = await gate.waitUntilEntered()
                    held = entered && gate.workerIsHeld && actualTask != nil && queue.activeCount == 1
                        && queue.pendingCount == 0 && queue.retainedByteCount == candidate.retainedBytes
                        && gate.startedIDs == [id] && gate.mainThreadFlags == [false] && completed.values.isEmpty
                    if !held {
                        await self.releaseAndDrainCandidate(queue: queue, gate: gate, actualTask: actualTask)
                        try #require(held, "actual held candidate ownership prerequisite")
                    }
                }
            }, beforeIndex: { ready in
                guard mode == "held" else { return }
                let prerequisites = held && !ready && gate.workerIsHeld && actualTask != nil
                    && queue.activeCount == 1 && queue.pendingCount == 0
                    && queue.retainedByteCount == candidate.retainedBytes && completed.values.isEmpty
                    && gate.startedIDs == [id] && gate.mainThreadFlags == [false] && !safetyState.expired
                if !prerequisites {
                    await self.releaseAndDrainCandidate(queue: queue, gate: gate, actualTask: actualTask)
                    try #require(prerequisites, "actual candidate readiness failure prerequisites")
                }
                try self.emitCandidate(["mode": "held", "prerequisites": prerequisites,
                    "heldActualWorker": held && gate.workerIsHeld, "actualTaskCaptured": actualTask != nil,
                    "offMain": gate.mainThreadFlags == [false], "activeCount": queue.activeCount,
                    "pendingCount": queue.pendingCount, "retainedBytes": queue.retainedByteCount,
                    "expectedRetainedBytes": candidate.retainedBytes, "completionCount": completed.values.count,
                    "readiness": ready, "safetyDidNotExpire": !safetyState.expired,
                    "ownerID": candidate.ownerID.uuidString, "generation": candidate.generation,
                    "sequence": candidate.sequence, "itemID": candidate.itemID])
            })
        // Neutral held mode reaches the unchecked index only after the evidence above.
        await actualTask?.value
        let ordinary = actualTask != nil && queue.isIdle && queue.retainedByteCount == 0
            && completed.values.count == 1 && completed.values.first?.0.ownerID == owner
            && completed.values.first?.0.generation == 7 && completed.values.first?.0.sequence == 1
            && completed.values.first?.0.itemID == id && completed.values.first?.0.queueOrder == order
            && completed.values.first?.1 == true && gate.normalizedTexts.map(\.1) == [text]
            && gate.mainThreadFlags == [false]
        let fifo = try await candidateRevalidationFixture()
        let cleanup = try await candidateExplicitReleaseControl()
        try emitCandidate(["mode": "ordinary", "prerequisites": ordinary && fifo && cleanup,
            "ordinaryPassed": ordinary && fifo, "cleanupControlPassed": cleanup])
        try #require(ordinary && fifo && cleanup, "actual ordinary candidate/FIFO output and explicit cleanup control")
    }

    private func releaseAndDrainCandidate(queue: LiveReplyPreparationQueue,
                                         gate: LiveReplyPreparationNormalizerGate,
                                         actualTask: Task<Void, Never>?) async {
        gate.releaseBlockedWork()
        let deadline = ContinuousClock.now + .seconds(3)
        while !queue.isIdle && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.001) { continuation.resume() }
            }
        }
        guard queue.isIdle else {
            print("PINCER_LIVE_CANDIDATE_SETUP_DRAIN_FAILED")
            fflush(stdout)
            Darwin._exit(2)
        }
        await actualTask?.value
    }

    private func candidateExplicitReleaseControl() async throws -> Bool {
        let owner = UUID(), id = "cleanup-candidate-" + UUID().uuidString
        let candidate = input(owner: owner, generation: 7, sequence: 1, id: id, text: "Cleanup candidate.")
        let gate = LiveReplyPreparationNormalizerGate(blockedIDs: [id])
        let queue = LiveReplyPreparationQueue(normalizer: { await gate.normalize($0) })
        let completed = LiveReplyCompletionRecorder()
        let admitted = queue.submit(candidate) { completed.append($0, $1) } == .started
        let task = queue.actualPreparationTaskForTesting
        let entered = await gate.waitUntilEntered()
        let held = admitted && entered && task != nil && gate.workerIsHeld && queue.activeCount == 1
            && completed.values.isEmpty && gate.mainThreadFlags == [false]
        await releaseAndDrainCandidate(queue: queue, gate: gate, actualTask: task)
        return held && queue.isIdle && queue.retainedByteCount == 0 && completed.values.count == 1
            && completed.values.first?.0.ownerID == owner && completed.values.first?.0.itemID == id
            && completed.values.first?.1 == true && gate.normalizedTexts.map(\.1) == ["Cleanup candidate."]
    }

    private func emitCandidate(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("PINCER_LIVE_CANDIDATE_CHILD_EVIDENCE=" + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
    #endif

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

#if DEBUG
private final class LiveReplyPreparationNormalizerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedIDs: Set<String>
    private var release = ExplicitWorkerTestGate()
    private var started: [String] = []
    private var normalizedText: [(String, String)] = []
    private var onMain: [Bool] = []
    private var didRelease = false

    var workerIsHeld: Bool { self.lock.withLock { !self.didRelease && !self.started.isEmpty } }

    init(blockedIDs: Set<String>) { self.blockedIDs = blockedIDs }

    var startedIDs: [String] { self.lock.withLock { self.started } }
    var normalizedTexts: [(String, String)] { self.lock.withLock { self.normalizedText } }
    var mainThreadFlags: [Bool] { self.lock.withLock { self.onMain } }

    func normalize(_ input: LiveReplyPreparationInput) async -> Bool {
        let heldGate = self.lock.withLock { () -> ExplicitWorkerTestGate? in
            self.started.append(input.itemID)
            self.normalizedText.append((input.itemID, input.textBlocks.joined(separator: "\n\n")))
            self.onMain.append(workerTestIsMainThread())
            return self.blockedIDs.remove(input.itemID) != nil ? self.release : nil
        }
        if let heldGate { await heldGate.hold() }
        return SpeechText.isSpeakable(textBlocks: input.textBlocks, itemID: input.itemID)
    }

    func waitUntilEntered() async -> Bool {
        let release = self.lock.withLock { self.release }
        return await release.waitUntilEntered()
    }

    func releaseBlockedWork() {
        let release = self.lock.withLock { () -> ExplicitWorkerTestGate? in
            guard !self.didRelease else { return nil }
            self.didRelease = true
            return self.release
        }
        release?.open()
    }
}
#endif

#if DEBUG && os(macOS)
private final class LiveCandidateSafety: @unchecked Sendable {
    private let lock = NSLock()
    private var didExpire = false
    func expire() { lock.withLock { didExpire = true } }
    var expired: Bool { lock.withLock { didExpire } }
}
#endif
