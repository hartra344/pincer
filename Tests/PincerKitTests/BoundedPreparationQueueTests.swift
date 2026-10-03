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
