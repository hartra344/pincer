import Foundation
@testable import PincerKit

#if DEBUG
private actor FindCheckGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold(_ ordinal: Int) async {
        guard ordinal <= 2 else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released { continuation.resume() }
                else { self.waiters.append(continuation) }
            }
        } onCancel: { Task { await self.releaseAll() } }
    }
    func releaseAll() {
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private func checkFindWorkers(entries: [TranscriptEntry], query: String, nextQuery: String) async {
    let expected = await Task.detached {
        (TranscriptSearch.matches(query, in: entries), TranscriptSearch.matches(nextQuery, in: entries),
         Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }.value
    check(!expected.0.isEmpty && !expected.1.isEmpty && entries.count <= 10,
          "ordinary nonempty matches qualify both actual matcher inputs")
    guard !expected.0.isEmpty && !expected.1.isEmpty && entries.count <= 10 else { return }
    let gate = FindCheckGate()
    let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
    let preparation = TranscriptFindPreparation()
    preparation.probe = probe
    let first = Task { await preparation.prepare(query: query, entries: entries, options: .init()) }
    let enteredFirst = await waitFor("first actual Find worker", timeout: 25) { probe.snapshot.entered == 1 }
    check(enteredFirst, "first actual detached matcher enters")
    guard enteredFirst else {
        first.cancel()
        await gate.releaseAll()
        _ = await first.value
        return
    }
    first.cancel()
    let second = Task { await preparation.prepare(query: nextQuery, entries: entries, options: .init()) }
    let admittedSecond = await waitFor("second Find request decision", timeout: 25) { probe.snapshot.requested == 2 }
    check(admittedSecond, "changed query reaches actual second request decision")
    if admittedSecond { check(probe.snapshot.maximumLeases == 1, "canceled Find caller retains the worker lease until completion") }
    await gate.releaseAll()
    let old = await first.value
    let current = await second.value
    check(old.matches == expected.0 && current.matches == expected.1 && current.rowIndex == expected.2,
          "actual completed matcher results and row indices remain exact")
    check(probe.snapshot.completed == 2 && probe.snapshot.active == 0 && probe.snapshot.leases == 0 && probe.snapshot.mainEntries == 0,
          "both actual workers finish off-main before fixture cleanup")
}

@MainActor
func runTranscriptFindWorkerChecks() async {
    let entries: [TranscriptEntry] = (0..<3).map {
        .user(ChatItem(id: "find-worker-\($0)", role: .user, blocks: [.text("needle ordinary message")], timestamp: Date(timeIntervalSince1970: 1)))
    }
    await checkFindWorkers(entries: entries, query: "needle", nextQuery: "message")
}

@MainActor
func runDemoTranscriptFindWorkerChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("Find worker Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "Find workers use a genuine connected Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    let loaded = await chat.loadFullHistory()
    check(loaded && !chat.entries.isEmpty && !chat.hasOlderItems, "actual Demo trip history is complete and nonempty")
    guard loaded && !chat.entries.isEmpty && !chat.hasOlderItems else { return }
    let inventory = chat.entries
    let entries = await Task.detached {
        Array(inventory.filter { !TranscriptSearch.matches("day", in: [$0]).isEmpty }.prefix(3))
    }.value
    check(entries.count == 3, "three actual Demo rows contain seeded day text")
    guard entries.count == 3 else { return }
    // Case-insensitive ordinary queries use the same real transcript without a wire overlay.
    await checkFindWorkers(entries: entries, query: "day", nextQuery: "DAY")
}
#endif
