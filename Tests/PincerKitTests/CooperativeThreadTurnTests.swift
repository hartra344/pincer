import Testing

/// #920: suites whose fakes park a pool thread must take turns, or a small CI runner's pool fills up.
@Suite("Cooperative thread turns")
struct CooperativeThreadTurnTests {
    private actor Tally {
        var active = 0, peak = 0, finished = 0
        func enter() { self.active += 1; self.peak = max(self.peak, self.active) }
        func leave() { self.active -= 1; self.finished += 1 }
    }

    @Test func turnsNeverOverlapAndEveryWaiterGetsOne() async {
        let turn = CooperativeThreadTurn()
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await turn.acquire()
                    await tally.enter()
                    await Task.yield()
                    await tally.leave()
                    await turn.release()
                }
            }
        }
        #expect(await tally.peak == 1)
        #expect(await tally.finished == 4)
    }

    @Test(.parksCooperativeThread) func theTraitHoldsTheSharedTurnForTheTest() async {
        let tally = Tally()
        // Gets its turn only once this test's scope releases it, then releases at once.
        Task {
            await CooperativeThreadTurn.shared.acquire()
            await tally.enter()
            await CooperativeThreadTurn.shared.release()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await tally.peak == 0, "another acquire waits while the test holds the turn")
    }
}
