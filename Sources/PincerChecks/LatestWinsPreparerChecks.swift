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
}
