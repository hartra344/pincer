import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Bounded preparation queue", .serialized)
struct BoundedPreparationQueueTests {
    @Test func pendingByteBudgetRejectsOnlyUnadmittedWorkAndPreservesFIFO() async {
        let queue = BoundedPreparationQueue<Int>()
        let gate = HeldOperations()
        let completions = CompletionRecorder()

        let first = queue.submit(retainedBytes: 40 * 1024 * 1024, operation: { await gate.run(0) }) {
            completions.values.append($0)
        }
        #expect(first == .started, "the active operation is not charged against pending bytes")
        #expect(await gate.waitForStarts(1))

        let accepted = queue.submit(retainedBytes: BoundedPreparationQueue<Int>.pendingByteLimit,
                                    operation: { await gate.run(1) }) {
            completions.values.append($0)
        }
        #expect(accepted == .queued)
        #expect(queue.activeCount == 1 && queue.pendingCount == 1)
        #expect(queue.pendingBytes == BoundedPreparationQueue<Int>.pendingByteLimit)

        let rejected = queue.submit(retainedBytes: 1, operation: { await gate.run(2) }) {
            completions.values.append($0)
        }
        #expect(rejected == .rejectedPendingBytes)
        #expect(queue.pendingCount == 1 && queue.pendingBytes == BoundedPreparationQueue<Int>.pendingByteLimit)
        #expect(gate.started == [0], "rejected work is never launched")

        gate.release(0)
        #expect(await gate.waitForStarts(2))
        #expect(completions.values == [0])
        #expect(queue.activeCount == 1 && queue.pendingCount == 0 && queue.pendingBytes == 0)
        gate.release(1)
        #expect(await eventually { completions.values == [0, 1] && queue.activeCount == 0 })
        #expect(completions.values == [0, 1], "each admitted item completes once in FIFO order")
    }

    @Test func pendingDescriptorCountHasExactLimitAndDrainsInOrder() async {
        let queue = BoundedPreparationQueue<Int>()
        let gate = HeldOperations()
        let completions = CompletionRecorder()
        let first = queue.submit(operation: { await gate.run(0) }) { completions.values.append($0) }
        #expect(first == .started)
        #expect(await gate.waitForStarts(1))

        for value in 1...BoundedPreparationQueue<Int>.pendingItemLimit {
            let admission = queue.submit(operation: { value }, completion: { completions.values.append($0) })
            #expect(admission == .queued)
        }
        #expect(queue.pendingCount == BoundedPreparationQueue<Int>.pendingItemLimit)
        #expect(queue.submit(operation: { 999 }, completion: { completions.values.append($0) }) == .rejectedPendingCount)

        gate.release(0)
        let expected = Array(0...BoundedPreparationQueue<Int>.pendingItemLimit)
        #expect(await eventually { completions.values == expected && queue.activeCount == 0 })
        #expect(completions.values == expected)
        #expect(queue.pendingBytes == 0 && queue.pendingCount == 0)
    }

    @Test func firedDeadlineCompletesWithTimeoutOutputFreesSlotAndDiscardsLateResult() async {
        let timers = TimerGate()
        let queue = BoundedPreparationQueue<Int>(itemDeadline: .seconds(60), timer: { _ in await timers.wait() })
        let gate = HeldOperations()
        let completions = CompletionRecorder()

        #expect(queue.submit(timeoutOutput: -1, operation: { await gate.run(0) }) { completions.values.append($0) } == .started)
        #expect(await gate.waitForStarts(1))
        #expect(queue.submit(timeoutOutput: -1, operation: { await gate.run(1) }) { completions.values.append($0) } == .queued)
        #expect(await eventually { timers.waiterCount == 1 })
        #expect(completions.values.isEmpty, "nothing times out until the injected timer fires")

        timers.fire(0)
        #expect(await gate.waitForStarts(2), "the next pending item starts once the hung one times out")
        #expect(completions.values == [-1])
        #expect(queue.activeCount == 1 && queue.pendingCount == 0)

        gate.release(0)
        for _ in 0..<5 { await Task.yield() }
        #expect(completions.values == [-1], "the hung operation's late result is discarded")

        gate.release(1)
        #expect(await eventually { completions.values == [-1, 1] && queue.activeCount == 0 })
        timers.fireAll()
        for _ in 0..<5 { await Task.yield() }
        #expect(completions.values == [-1, 1], "a timer returning after its item finished is ignored")
    }

    @Test func itemWithoutTimeoutOutputHasNoDeadline() async {
        let timers = TimerGate()
        let queue = BoundedPreparationQueue<Int>(itemDeadline: .seconds(60), timer: { _ in await timers.wait() })
        let gate = HeldOperations()
        let completions = CompletionRecorder()

        queue.submit(operation: { await gate.run(0) }) { completions.values.append($0) }
        #expect(await gate.waitForStarts(1))
        for _ in 0..<5 { await Task.yield() }
        #expect(timers.waiterCount == 0, "no timer is started without a timeoutOutput")
        gate.release(0)
        #expect(await eventually { completions.values == [0] && queue.activeCount == 0 })
    }

    @Test func cancellingAnOwnerDropsOnlyItsWorkAndPreservesOthersFIFO() async {
        let queue = BoundedPreparationQueue<Int>()
        let gate = HeldOperations()
        let completions = CompletionRecorder()
        let a = UUID(), b = UUID()

        queue.submit(owner: a, operation: { await gate.run(0) }) { completions.values.append($0) }
        #expect(await gate.waitForStarts(1))
        #expect(queue.submit(owner: b, retainedBytes: 10, operation: { await gate.run(1) }) { completions.values.append($0) } == .queued)
        #expect(queue.submit(owner: a, retainedBytes: 20, operation: { await gate.run(2) }) { completions.values.append($0) } == .queued)
        #expect(queue.submit(owner: b, retainedBytes: 30, operation: { await gate.run(3) }) { completions.values.append($0) } == .queued)
        #expect(queue.pendingBytes == 60)

        queue.cancel(owner: a)
        #expect(queue.pendingCount == 1 && queue.pendingBytes == 30,
                "the owner's pending bytes are released and the abandoned slot starts b's first item")
        #expect(await gate.waitForStarts(2), "abandoning the active item starts the next owner's work")
        #expect(gate.started == [0, 1])

        gate.release(0)
        for _ in 0..<5 { await Task.yield() }
        #expect(completions.values.isEmpty, "the abandoned active item never completes")
        gate.release(1)
        #expect(await gate.waitForStarts(3))
        gate.release(3)
        #expect(await eventually { completions.values == [1, 3] && queue.activeCount == 0 })
        #expect(gate.started == [0, 1, 3], "the cancelled owner's queued work never runs")
    }

    @Test func registryCancelsOwnerOnLiveQueuesAndDraftReplacementCancelsQueuedWork() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Cancel", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = gateway.chat(for: "agent:research:main")
        let queue = BoundedPreparationQueue<Int>()
        let gate = HeldOperations()
        let completions = CompletionRecorder()

        queue.submit(operation: { await gate.run(0) }) { completions.values.append($0) }
        #expect(await gate.waitForStarts(1))
        let owner = chat.draft.ownerID
        let token = chat.beginAttachmentPreparation(ownerID: owner)
        #expect(token != nil)
        #expect(queue.submit(owner: owner, retainedBytes: 5, operation: { await gate.run(1) }) { completions.values.append($0) } == .queued)
        #expect(queue.pendingCount == 1)

        chat.draft = ComposerDraft()
        #expect(queue.pendingCount == 0 && queue.pendingBytes == 0, "retiring the draft cancels its queued preparation")

        gate.release(0)
        #expect(await eventually { completions.values == [0] && queue.activeCount == 0 })
        #expect(gate.started == [0], "the retired owner's operation never starts")

        let other = UUID()
        queue.submit(owner: other, operation: { await gate.run(2) }) { completions.values.append($0) }
        #expect(await gate.waitForStarts(2))
        PreparationOwnerCancellation.cancel(owner: other)
        #expect(queue.activeCount == 0)
    }

    private final class TimerGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>?] = []
        var waiterCount: Int { self.lock.withLock { self.waiters.count } }

        func wait() async {
            await withCheckedContinuation { continuation in
                self.lock.withLock { self.waiters.append(continuation) }
            }
        }

        func fire(_ index: Int) {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { self.waiters[index] = nil }
                return self.waiters[index]
            }
            continuation?.resume()
        }

        func fireAll() { for index in 0..<self.waiterCount { self.fire(index) } }
    }

    @MainActor
    private final class CompletionRecorder {
        var values: [Int] = []
    }

    @MainActor
    private final class HeldOperations {
        private(set) var started: [Int] = []
        private var releases: [Int: CheckedContinuation<Int, Never>] = [:]

        func run(_ value: Int) async -> Int {
            self.started.append(value)
            return await withCheckedContinuation { self.releases[value] = $0 }
        }

        func waitForStarts(_ count: Int) async -> Bool {
            await eventually { self.started.count >= count }
        }

        func release(_ value: Int) {
            self.releases.removeValue(forKey: value)?.resume(returning: value)
        }
    }
}
