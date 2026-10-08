import Synchronization
import Testing

/// #920: suites whose fakes park a pool thread must take turns, or a small CI runner's pool fills up.
@Suite("Cooperative thread turns")
struct CooperativeThreadTurnTests {
    @Test func turnsNeverOverlapAndEveryWaiterGetsOne() async {
        let turn = CooperativeThreadTurn()
        let active = Mutex(0)
        let peak = Mutex(0)
        let finished = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await turn.acquire()
                    let now = active.withLock { $0 += 1; return $0 }
                    peak.withLock { $0 = max($0, now) }
                    await Task.yield()
                    active.withLock { $0 -= 1 }
                    finished.withLock { $0 += 1 }
                    await turn.release()
                }
            }
        }
        #expect(peak.withLock { $0 } == 1)
        #expect(finished.withLock { $0 } == 4)
    }

    @Test(.parksCooperativeThread) func theTraitHoldsTheSharedTurnForTheTest() async {
        // Inside the trait's scope the shared turn is taken, so another acquire must wait.
        let acquired = Mutex(false)
        let other = Task {
            await CooperativeThreadTurn.shared.acquire()
            acquired.withLock { $0 = true }
            await CooperativeThreadTurn.shared.release()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(acquired.withLock { $0 } == false)
        other.cancel()
        // `other` gets its turn once this test's scope releases it; it then releases at once.
    }
}
