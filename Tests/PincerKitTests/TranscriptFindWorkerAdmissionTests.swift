import Foundation
import Testing
@testable import PincerKit

#if DEBUG
actor FindWorkerGate {
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
@Suite("Find worker admission", .timeLimit(.minutes(2)))
struct TranscriptFindWorkerAdmissionTests {
    func rows() -> [TranscriptEntry] {
        (0..<3).map { .user(ChatItem(id: "worker-\($0)", role: .user, blocks: [.text("needle ordinary message")], timestamp: Date(timeIntervalSince1970: 1))) }
    }
    func entered(_ probe: TranscriptFindWorkerProbe, count: Int) async throws {
        while probe.snapshot.entered < count {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
    @Test func canceledCallerRetainsWorkerLeaseUntilActualCompletion() async throws {
        let preparation = TranscriptFindPreparation()
        let gate = FindWorkerGate()
        let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
        preparation.probe = probe
        let rows = self.rows()
        let first = Task { await preparation.prepare(query: "needle", entries: rows, options: .init()) }
        var second: Task<TranscriptFindPreparation.Result, Never>?
        do {
            try await self.entered(probe, count: 1)
            first.cancel()
            let next = Task { await preparation.prepare(query: "message", entries: rows, options: .init()) }
            second = next
            while probe.snapshot.requested < 2 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            #expect(probe.snapshot.maximumLeases == 1)
            await gate.releaseAll()
            let oldResult = await first.value
            let newResult = await next.value
            #expect(oldResult.matches.count == 3 && newResult.matches.count == 3)
            #expect(newResult.rowIndex == Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }))
            #expect(probe.snapshot.completed == 2 && probe.snapshot.active == 0 && probe.snapshot.leases == 0 && probe.snapshot.mainEntries == 0)
        } catch {
            first.cancel()
            second?.cancel()
            await gate.releaseAll()
            _ = await first.value
            if let second { _ = await second.value }
            throw error
        }
    }
    @Test func ordinaryMatcherProducesExactMatchesAndRows() async {
        let preparation = TranscriptFindPreparation()
        let probe = TranscriptFindWorkerProbe()
        preparation.probe = probe
        let rows = self.rows()
        let result = await preparation.prepare(query: "needle", entries: rows, options: .init())
        #expect(result.matches == rows.map { .init(entryId: $0.id, section: .message(0), occurrence: 0) })
        #expect(result.rowIndex.count == 3)
        #expect(probe.snapshot.entered == 1 && probe.snapshot.completed == 1 && probe.snapshot.maximumActive == 1 && probe.snapshot.mainEntries == 0)
    }
}
#endif
