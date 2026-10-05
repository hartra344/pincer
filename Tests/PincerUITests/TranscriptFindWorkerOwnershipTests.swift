import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

#if DEBUG
private actor FindUIWorkerGate {
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
@Suite("Actual Find worker ownership", .timeLimit(.minutes(2)))
struct TranscriptFindWorkerOwnershipTests {
    @Test func actualQueryChangeCannotOverlapCanceledMatcher() async throws {
        let preparation = TranscriptFindPreparation()
        let gate = FindUIWorkerGate()
        let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
        preparation.probe = probe
        let find = TranscriptFind(preparation: preparation)
        let rows: [TranscriptEntry] = (0..<3).map {
            .user(ChatItem(id: "find-worker-\($0)", role: .user, blocks: [.text("needle ordinary message")], timestamp: Date(timeIntervalSince1970: 1)))
        }
        find.update(entries: rows, reasoningOff: false)
        find.present(query: "needle", select: nil)
        let old = find.activeSearchForChecks
        var current: Task<Void, Never>?
        do {
            let oldTask = try #require(old)
            while probe.snapshot.entered < 1 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            find.query = "message"
            current = find.activeSearchForChecks
            let currentTask = try #require(current)
            while probe.snapshot.requested < 2 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            #expect(probe.snapshot.maximumLeases == 1)
            await gate.releaseAll()
            await oldTask.value
            await currentTask.value
            #expect(!find.isSearching && find.matches == rows.map { .init(entryId: $0.id, section: .message(0), occurrence: 0) })
            #expect(probe.snapshot.completed == 2 && probe.snapshot.active == 0 && probe.snapshot.leases == 0 && probe.snapshot.mainEntries == 0)
            find.dismiss()
        } catch {
            find.dismiss()
            old?.cancel()
            current?.cancel()
            await gate.releaseAll()
            await old?.value
            await current?.value
            throw error
        }
    }
}
#endif
