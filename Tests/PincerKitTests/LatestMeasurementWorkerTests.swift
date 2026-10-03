import Foundation

// Snapshot the synchronous operation entry before its first suspension.
private func measurementOperationRunsOffMain() -> Bool { !Thread.isMainThread }
import Testing
@testable import PincerKit

private actor HeldMeasurementOperations {
    struct Result: Sendable, Equatable {
        let input: Int
        let ranOffMain: Bool
    }

    private(set) var started: [Int] = []
    private var releases: [Int: (CheckedContinuation<Result, Never>, Bool)] = [:]
    private var isClosed = false

    func run(_ input: Int, ranOffMain: Bool) async -> Result {
        if self.isClosed { return Result(input: input, ranOffMain: ranOffMain) }
        return await withCheckedContinuation { continuation in
            self.started.append(input)
            self.releases[input] = (continuation, ranOffMain)
        }
    }

    func waitForStarts(_ count: Int, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.started.count < count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func release(_ input: Int) {
        guard let (continuation, ranOffMain) = self.releases.removeValue(forKey: input) else { return }
        continuation.resume(returning: Result(input: input, ranOffMain: ranOffMain))
    }

    func releaseAll() {
        self.isClosed = true
        for (input, (continuation, ranOffMain)) in self.releases {
            continuation.resume(returning: Result(input: input, ranOffMain: ranOffMain))
        }
        self.releases.removeAll()
    }
}

@MainActor
@Suite("Latest measurement worker")
struct LatestMeasurementWorkerTests {
    @Test func coalescesToLatestAndRunsOperationOffMain() async {
        let operations = HeldMeasurementOperations()
        let worker = LatestMeasurementWorker<Int, HeldMeasurementOperations.Result> { input in
            let ranOffMain = measurementOperationRunsOffMain()
            return await operations.run(input, ranOffMain: ranOffMain)
        }
        var delivered: [HeldMeasurementOperations.Result] = []
        worker.submit(1) { delivered.append($0) }
        guard await operations.waitForStarts(1) else {
            await operations.releaseAll()
            Issue.record("the first detached measurement should start")
            return
        }

        worker.submit(2) { delivered.append($0) }
        worker.submit(3) { delivered.append($0) }
        #expect(worker.activeCount == 1 && worker.pendingCount == 1)

        await operations.release(1)
        guard await operations.waitForStarts(2) else {
            await operations.releaseAll()
            Issue.record("the newest pending measurement should start after the active one exits")
            return
        }
        let started = await operations.started
        #expect(started == [1, 3], "the intermediate pending measurement is replaced")
        #expect(delivered.isEmpty, "an older active result is stale after a newer submission")

        await operations.release(3)
        let completed = await eventually { delivered.count == 1 }
        #expect(completed)
        #expect(delivered == [.init(input: 3, ranOffMain: true)])
        #expect(worker.activeCount == 0 && worker.pendingCount == 0)
        await operations.releaseAll()
    }

    @Test func invalidateKeepsActiveSlotUntilExitAndAllowsLatestResubmission() async {
        let operations = HeldMeasurementOperations()
        let worker = LatestMeasurementWorker<Int, HeldMeasurementOperations.Result> { input in
            let ranOffMain = measurementOperationRunsOffMain()
            return await operations.run(input, ranOffMain: ranOffMain)
        }
        var delivered: [Int] = []
        worker.submit(10) { delivered.append($0.input) }
        guard await operations.waitForStarts(1) else {
            await operations.releaseAll()
            Issue.record("the measurement should start")
            return
        }

        worker.invalidate()
        #expect(worker.activeCount == 1 && worker.pendingCount == 0)
        worker.submit(20) { delivered.append($0.input) }
        #expect(worker.activeCount == 1 && worker.pendingCount == 1)

        await operations.release(10)
        guard await operations.waitForStarts(2) else {
            await operations.releaseAll()
            Issue.record("resubmitted work should wait for the cancelled operation to retire")
            return
        }
        let started = await operations.started
        #expect(started == [10, 20])
        #expect(delivered.isEmpty, "invalidated work must not publish")

        await operations.release(20)
        let completed = await eventually { delivered == [20] }
        #expect(completed)
        #expect(worker.activeCount == 0 && worker.pendingCount == 0)
        await operations.releaseAll()
    }

    @Test func callbackMaySubmitReentrantlyAfterActiveSlotIsCleared() async {
        let worker = LatestMeasurementWorker<Int, Int> { input in
            await Task.yield()
            return input
        }
        var delivered: [Int] = []
        worker.submit(1) { first in
            #expect(worker.activeCount == 0)
            delivered.append(first)
            worker.submit(2) { delivered.append($0) }
        }

        let completed = await eventually { delivered == [1, 2] }
        #expect(completed)
        #expect(worker.activeCount == 0 && worker.pendingCount == 0)
    }

    @Test func invalidatingPendingWorkDoesNotLaunchIt() async {
        let operations = HeldMeasurementOperations()
        let worker = LatestMeasurementWorker<Int, HeldMeasurementOperations.Result> { input in
            let ranOffMain = measurementOperationRunsOffMain()
            return await operations.run(input, ranOffMain: ranOffMain)
        }
        var delivered: [Int] = []
        worker.submit(1) { delivered.append($0.input) }
        guard await operations.waitForStarts(1) else {
            await operations.releaseAll()
            Issue.record("the active measurement should start")
            return
        }
        worker.submit(2) { delivered.append($0.input) }
        worker.invalidate()
        #expect(worker.activeCount == 1 && worker.pendingCount == 0)
        await operations.release(1)
        let idle = await eventually { worker.activeCount == 0 && worker.pendingCount == 0 }
        #expect(idle)
        let started = await operations.started
        #expect(started == [1])
        #expect(delivered.isEmpty)
        await operations.releaseAll()
    }
}
