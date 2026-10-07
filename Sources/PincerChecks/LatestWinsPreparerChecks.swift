import Foundation
import Synchronization
@testable import PincerKit

private actor LWLatch {
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

private final class LWWorkers: Sendable {
    private struct State { var started: [Int] = []; var running = 0; var maxRunning = 0 }
    private let state = Mutex(State())
    private let latches = Mutex<[Int: LWLatch]>([:])

    private func latch(_ id: Int) -> LWLatch {
        latches.withLock { d in
            if let l = d[id] { return l }
            let l = LWLatch()
            d[id] = l
            return l
        }
    }

    var started: [Int] { state.withLock { $0.started } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    func work(_ id: Int) -> @Sendable () async -> Int {
        { [self] in
            state.withLock { $0.started.append(id); $0.running += 1; $0.maxRunning = max($0.maxRunning, $0.running) }
            await latch(id).wait()
            state.withLock { $0.running -= 1 }
            return id
        }
    }

    func release(_ id: Int) async { await latch(id).open() }
}

private final class LWCancelProbe: Sendable {
    private let state = Mutex<(started: [Int], cancelled: Set<Int>)>(([], []))
    private let latches = Mutex<[Int: LWLatch]>([:])

    private func latch(_ id: Int) -> LWLatch {
        latches.withLock { d in
            if let l = d[id] { return l }
            let l = LWLatch()
            d[id] = l
            return l
        }
    }

    var started: [Int] { state.withLock { $0.started } }
    func wasCancelled(_ id: Int) -> Bool { state.withLock { $0.cancelled.contains(id) } }

    func work(_ id: Int) -> @Sendable () async -> Int {
        { [self] in
            await withTaskCancellationHandler {
                state.withLock { $0.started.append(id) }
                await latch(id).wait()
                return id
            } onCancel: {
                state.withLock { _ = $0.cancelled.insert(id) }
            }
        }
    }

    func release(_ id: Int) async { await latch(id).open() }
}

@MainActor
func runLatestWinsPreparerChecks() async {
    let p = LatestWinsPreparer<Int>()
    let w = LWWorkers()
    var results: [Int: [Int?]] = [:]
    func submit(_ id: Int) {
        p.submit(work: w.work(id)) { results[id, default: []].append($0) }
    }

    submit(1)
    check(p.activeCount == 1 && p.pendingCount == 0, "the first request starts at once")
    submit(2)
    submit(3)
    check(p.pendingCount == 1 && results[2] == [nil], "a replaced pending request completes nil immediately")
    let started1 = await waitFor("first worker starts", timeout: 2) { w.started == [1] }
    check(started1 && w.started == [1], "the pending request waits for the active worker")
    await w.release(1)
    let started3 = await waitFor("replacement starts after exit", timeout: 2) { w.started == [1, 3] }
    check(started3, "the latest pending request starts once the active worker exits")
    await w.release(3)
    await p.waitForIdle()
    check(results[1] == [nil], "a superseded active request delivers nil")
    check(results[3] == [3], "the latest request delivers its value")
    check(w.maxRunning == 1 && !w.started.contains(2), "never two workers at once and the replaced request never runs")

    submit(4)
    submit(5)
    p.invalidate()
    check(results[5] == [nil] && p.pendingCount == 0 && p.activeCount == 1, "invalidate drops pending but the active worker keeps its lease")
    await w.release(4)
    await p.waitForIdle()
    check(results[4] == [nil] && p.activeCount == 0, "an invalidated active request delivers nil after its worker exits")

    let t6 = p.submit(work: w.work(6)) { results[6, default: []].append($0) }
    p.cancel(t6)
    await w.release(6)
    await p.waitForIdle()
    check(results[6] == [nil], "a cancelled active request delivers nil exactly once")

    let task = Task { @MainActor in await p.prepare(work: w.work(7)) }
    let started7 = await waitFor("prepare worker starts", timeout: 2) { w.started.contains(7) }
    task.cancel()
    await w.release(7)
    let value = await task.value
    await p.waitForIdle()
    check(started7 && value == nil, "task cancellation of an active prepare() returns nil")

    await runLatestWinsReentrancyChecks()
    await runLatestWinsOwnerReleaseChecks()
    await runLatestWinsCancellationChecks()
}

@MainActor
private func runLatestWinsReentrancyChecks() async {
    let p = LatestWinsPreparer<Int>()
    let w = LWWorkers()
    var results: [Int: [Int?]] = [:]
    func submit(_ id: Int, reentrantID: Int? = nil) {
        p.submit(work: w.work(id)) { value in
            results[id, default: []].append(value)
            if let reentrantID {
                p.submit(work: w.work(reentrantID)) { results[reentrantID, default: []].append($0) }
            }
        }
    }
    submit(1)
    submit(2, reentrantID: 4)
    submit(3)
    check(results[2] == [nil] && results[3] == [nil] && p.pendingCount == 1,
          "a submit from the displaced request's completion replaces the request that displaced it")
    await w.release(1)
    let started4 = await waitFor("re-entrant request starts", timeout: 2) { w.started == [1, 4] }
    await w.release(4)
    await p.waitForIdle()
    check(started4 && results[4] == [4], "the newest request delivers after a re-entrant submit")
    check((1...4).allSatisfy { results[$0]?.count == 1 }, "every request completes exactly once with a re-entrant submit")
}

@MainActor
private func runLatestWinsOwnerReleaseChecks() async {
    let w = LWWorkers()
    var results: [Int: [Int?]] = [:]
    var seen: [Int] = []
    var p: LatestWinsPreparer<Int>? = LatestWinsPreparer<Int>()
    p?.submit(work: w.work(1), finished: { seen.append($0) }) { results[1, default: []].append($0) }
    p?.submit(work: w.work(2), finished: { seen.append($0) }) { results[2, default: []].append($0) }
    _ = await waitFor("owner-release first worker starts", timeout: 2) { w.started == [1] }
    p = nil
    await w.release(1)
    let started2 = await waitFor("pending runs after owner release", timeout: 2) { w.started == [1, 2] }
    await w.release(2)
    let done = await waitFor("both requests complete after owner release", timeout: 2) {
        results[1]?.count == 1 && results[2]?.count == 1
    }
    check(started2 && done && results[1] == [nil] && results[2] == [2],
          "releasing the preparer still runs the pending request and completes every request once")
    check(seen == [1, 2], "finished still sees the active worker's output after owner release")
}

@MainActor
private func runLatestWinsCancellationChecks() async {
    let cancelling = LatestWinsPreparer<Int>(cancelsSupersededWork: true)
    let probe = LWCancelProbe()
    var results: [Int: [Int?]] = [:]
    func submit(_ p: LatestWinsPreparer<Int>, _ id: Int) -> LatestWinsPreparer<Int>.Ticket {
        p.submit(work: probe.work(id)) { results[id, default: []].append($0) }
    }
    _ = submit(cancelling, 1)
    _ = await waitFor("cancelling worker starts", timeout: 2) { probe.started == [1] }
    check(!probe.wasCancelled(1), "an uncontested worker is not cancelled")
    _ = submit(cancelling, 2)
    let cancelled1 = await waitFor("superseded worker cancelled", timeout: 2) { probe.wasCancelled(1) }
    check(cancelled1 && cancelling.activeCount == 1 && probe.started == [1],
          "superseding cancels the active worker but it keeps the lease until it exits")
    await probe.release(1)
    _ = await waitFor("replacement starts", timeout: 2) { probe.started == [1, 2] }
    check(!probe.wasCancelled(2), "the replacement is not cancelled")
    await probe.release(2)
    await cancelling.waitForIdle()
    check(results[1] == [nil] && results[2] == [2], "the cancelled request delivers nil and the latest delivers")

    let t3 = submit(cancelling, 3)
    _ = await waitFor("worker 3 starts", timeout: 2) { probe.started.contains(3) }
    cancelling.cancel(t3)
    let cancelled3 = await waitFor("cancelled ticket cancels worker", timeout: 2) { probe.wasCancelled(3) }
    check(cancelled3 && cancelling.activeCount == 1, "cancel(ticket) cancels the active worker, lease held")
    await probe.release(3)
    await cancelling.waitForIdle()
    _ = submit(cancelling, 4)
    _ = await waitFor("worker 4 starts", timeout: 2) { probe.started.contains(4) }
    cancelling.invalidate()
    let cancelled4 = await waitFor("invalidate cancels worker", timeout: 2) { probe.wasCancelled(4) }
    check(cancelled4 && cancelling.activeCount == 1, "invalidate cancels the active worker, lease held")
    await probe.release(4)
    await cancelling.waitForIdle()
    check(results[3] == [nil] && results[4] == [nil] && cancelling.activeCount == 0, "cancelled workers deliver nil once")

    let plain = LatestWinsPreparer<Int>()
    let t5 = submit(plain, 5)
    _ = await waitFor("plain worker starts", timeout: 2) { probe.started.contains(5) }
    _ = submit(plain, 6)
    plain.cancel(t5)
    plain.invalidate()
    await probe.release(5)
    await plain.waitForIdle()
    check(!probe.wasCancelled(5) && !probe.started.contains(6), "the default preparer never cancels its worker")
}
