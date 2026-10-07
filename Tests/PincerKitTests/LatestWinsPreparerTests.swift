import Foundation
import Synchronization
import Testing
@testable import PincerKit

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}

/// Worker bookkeeping: each id's worker blocks on its own latch until the test opens it.
private final class Workers: Sendable {
    private struct State {
        var started: [Int] = []
        var running = 0
        var maxRunning = 0
        var mainThreadFlags: [Bool] = []
    }

    private let state = Mutex(State())
    private let latches = Mutex<[Int: Latch]>([:])

    private func latch(_ id: Int) -> Latch {
        latches.withLock { dict in
            if let l = dict[id] { return l }
            let l = Latch()
            dict[id] = l
            return l
        }
    }

    var started: [Int] { state.withLock { $0.started } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }
    var ranOnMain: Bool { state.withLock { $0.mainThreadFlags.contains(true) } }

    func work(_ id: Int) -> @Sendable () async -> Int {
        { [self] in
            state.withLock {
                $0.started.append(id)
                $0.running += 1
                $0.maxRunning = max($0.maxRunning, $0.running)
                $0.mainThreadFlags.append(Thread.isMainThread)
            }
            await latch(id).wait()
            state.withLock { $0.running -= 1 }
            return id
        }
    }

    func release(_ id: Int) async { await latch(id).open() }
}

@MainActor
private final class Log {
    var results: [(Int, Int?)] = []
    func calls(_ tag: Int) -> [Int?] { results.filter { $0.0 == tag }.map(\.1) }
}

private final class Token: Sendable {}

@MainActor
@Suite("Latest-wins preparer", .serialized)
struct LatestWinsPreparerTests {
    private func submit(_ p: LatestWinsPreparer<Int>, _ w: Workers, _ log: Log, _ id: Int,
                        accept: @escaping @MainActor () -> Bool = { true },
                        finished: (@MainActor (Int) -> Void)? = nil) -> LatestWinsPreparer<Int>.Ticket {
        p.submit(accept: accept, work: w.work(id), finished: finished) { log.results.append((id, $0)) }
    }

    private func drain(_ p: LatestWinsPreparer<Int>) async {
        await p.waitForIdle()
    }

    @Test func firstSubmitStartsImmediatelyOffMain() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        #expect(p.activeCount == 1 && p.pendingCount == 0)
        #expect(await eventually { w.started == [1] })
        #expect(!w.ranOnMain)
        await w.release(1)
        await drain(p)
        #expect(log.calls(1) == [1])
        #expect(p.isIdle && p.currentTicket != nil)
    }

    @Test func thirdSubmitReplacesPendingWhichCompletesNilOnce() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        _ = submit(p, w, log, 2)
        #expect(p.activeCount == 1 && p.pendingCount == 1)
        _ = submit(p, w, log, 3)
        #expect(p.pendingCount == 1)
        #expect(log.calls(2) == [nil], "the replaced pending request completes nil immediately")
        await w.release(1)
        #expect(await eventually { w.started == [1, 3] })
        await w.release(3)
        await drain(p)
        #expect(log.calls(1) == [nil], "the superseded active request delivers nil")
        #expect(log.calls(2) == [nil])
        #expect(log.calls(3) == [3])
        #expect(w.maxRunning == 1)
        #expect(!w.started.contains(2))
    }

    @Test func pendingStartsOnlyAfterActiveWorkerExits() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        _ = submit(p, w, log, 2)
        #expect(await eventually { w.started == [1] })
        let worker = p.workerTask
        await w.release(1)
        await worker?.value
        #expect(p.activeCount == 1, "the next worker took over")
        #expect(await eventually { w.started == [1, 2] })
        await w.release(2)
        await drain(p)
        #expect(w.maxRunning == 1)
        #expect(log.calls(2) == [2])
    }

    @Test func invalidateDropsPendingAndActiveFinishesNilAfterExit() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        _ = submit(p, w, log, 2)
        p.invalidate()
        #expect(log.calls(2) == [nil])
        #expect(p.pendingCount == 0 && p.activeCount == 1 && p.currentTicket == nil)
        #expect(log.calls(1).isEmpty)
        await w.release(1)
        await drain(p)
        #expect(log.calls(1) == [nil])
        #expect(w.started == [1])
        #expect(p.activeCount == 0)
    }

    @Test func cancelPendingAndActive() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        let t1 = submit(p, w, log, 1)
        let t2 = submit(p, w, log, 2)
        p.cancel(t2)
        #expect(log.calls(2) == [nil] && p.pendingCount == 0)
        p.cancel(t1)
        #expect(p.activeCount == 1 && log.calls(1).isEmpty)
        await w.release(1)
        await drain(p)
        #expect(log.calls(1) == [nil])
        p.cancel(t1)
        #expect(log.calls(1) == [nil], "cancelling a finished ticket is a no-op")
    }

    @Test func asyncPrepareReturnsValue() async {
        let p = LatestWinsPreparer<Int>(), w = Workers()
        await w.release(7)
        #expect(await p.prepare(work: w.work(7)) == 7)
    }

    @Test func cancellationWhilePendingReturnsNilAndWorkerNeverRuns() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        let task = Task { @MainActor in await p.prepare(work: w.work(2)) }
        #expect(await eventually { p.pendingCount == 1 })
        task.cancel()
        #expect(await task.value == nil)
        #expect(p.pendingCount == 0)
        await w.release(1)
        await drain(p)
        #expect(w.started == [1])
        #expect(log.calls(1) == [1])
    }

    @Test func cancellationWhileActiveReturnsNilAfterWorkerExitsAndNextRequestRuns() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        let task = Task { @MainActor in await p.prepare(work: w.work(1)) }
        #expect(await eventually { w.started == [1] })
        task.cancel()
        _ = submit(p, w, log, 2)
        #expect(p.pendingCount == 1)
        await w.release(1)
        #expect(await task.value == nil)
        #expect(await eventually { w.started == [1, 2] })
        await w.release(2)
        await drain(p)
        #expect(log.calls(2) == [2])
        #expect(w.maxRunning == 1)
    }

    @Test func cancelledBeforePrepareStartsReturnsNilWithoutRunning() async {
        let p = LatestWinsPreparer<Int>(), w = Workers()
        let task = Task { @MainActor () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await p.prepare(work: w.work(1))
        }
        #expect(await task.value == nil)
        #expect(w.started.isEmpty && p.isIdle)
    }

    @Test func acceptFalseDeliversNilAndFinishedSeesEveryOutput() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        var seen: [Int] = []
        _ = submit(p, w, log, 1, accept: { false }, finished: { seen.append($0) })
        _ = submit(p, w, log, 2, finished: { seen.append($0) })
        await w.release(1)
        await w.release(2)
        await drain(p)
        #expect(seen == [1, 2], "finished fires even for a superseded output")
        #expect(log.calls(1) == [nil] && log.calls(2) == [2])

        _ = submit(p, w, log, 3, accept: { false })
        await w.release(3)
        await drain(p)
        #expect(log.calls(3) == [nil])
    }

    @Test func startBuilderRunsOnMainOnlyWhenRequestBecomesActive() async {
        let p = LatestWinsPreparer<Int>(), w = Workers()
        var built: [Int] = []
        var results: [Int?] = []
        _ = p.submit(start: { built.append(1); return w.work(1) }) { results.append($0) }
        #expect(built == [1], "an idle preparer starts at submit time")
        _ = p.submit(start: { built.append(2); return w.work(2) }) { results.append($0) }
        #expect(built == [1], "a queued request is not built yet")
        _ = p.submit(start: { built.append(3); return w.work(3) }) { results.append($0) }
        #expect(built == [1])
        await w.release(1)
        #expect(await eventually { built == [1, 3] })
        await w.release(3)
        await p.waitForIdle()
        #expect(results.count == 3 && results[0] == nil && results[1] == nil && results[2] == 3)
        #expect(!built.contains(2))
    }

    @Test func waitForIdleReturnsWhenDrainedAndImmediatelyWhenIdle() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        await p.waitForIdle()
        _ = submit(p, w, log, 1)
        _ = submit(p, w, log, 2)
        let waiter = Task { @MainActor in await p.waitForIdle(); return p.isIdle }
        await w.release(1)
        await w.release(2)
        #expect(await waiter.value)
        #expect(log.calls(1) == [nil] && log.calls(2) == [2])
    }

    @Test func everyRequestCompletesExactlyOnce() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        let t1 = submit(p, w, log, 1)
        _ = submit(p, w, log, 2)
        _ = submit(p, w, log, 3)
        p.cancel(t1)
        p.invalidate()
        _ = submit(p, w, log, 4)
        for id in 1...4 { await w.release(id) }
        await drain(p)
        for id in 1...4 { #expect(log.calls(id).count == 1, "request \(id)") }
        #expect(log.calls(4) == [4])
    }

    @Test func deallocatedPreparerCompletesNil() async {
        let w = Workers(), log = Log()
        var p: LatestWinsPreparer<Int>? = LatestWinsPreparer<Int>()
        _ = submit(p!, w, log, 1)
        #expect(await eventually { w.started == [1] })
        p = nil
        await w.release(1)
        #expect(await eventually { log.calls(1).count == 1 })
        #expect(log.calls(1) == [nil])
    }

    @Test func replacedPendingRequestReleasesItsInput() async {
        let p = LatestWinsPreparer<Int>(), w = Workers(), log = Log()
        _ = submit(p, w, log, 1)
        weak var weakToken: Token?
        do {
            let token = Token()
            weakToken = token
            _ = p.submit(work: { _ = token; return 2 }) { log.results.append((2, $0)) }
        }
        #expect(weakToken != nil, "the pending input is retained while pending")
        _ = submit(p, w, log, 3)
        #expect(weakToken == nil, "a replaced pending input is released")
        await w.release(1)
        await w.release(3)
        await drain(p)
    }
}
