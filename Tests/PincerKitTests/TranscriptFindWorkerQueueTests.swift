import Foundation
import Testing
@testable import PincerKit

#if DEBUG
@MainActor
@Suite("Find worker queue ownership", .timeLimit(.minutes(2)))
struct TranscriptFindWorkerQueueTests {
    func rows() -> [TranscriptEntry] {
        (0..<3).map { .user(ChatItem(id: "queue-\($0)", role: .user, blocks: [.text("needle ordinary message")], timestamp: Date(timeIntervalSince1970: 1))) }
    }
    enum ReadinessFailure: Error { case deadline }
    final class Completion { var finished = false }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ReadinessFailure.deadline }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
    @Test func latestPendingReplacesEarlierWithoutStartingAnotherWorker() async throws {
        let preparation = TranscriptFindPreparation()
        let gate = FindWorkerGate()
        let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
        preparation.probe = probe
        let rows = self.rows()
        let first = Task { await preparation.prepare(query: "needle", entries: rows, options: .init()) }
        var second: Task<TranscriptFindPreparation.Result, Never>?
        var latest: Task<TranscriptFindPreparation.Result, Never>?
        do {
            try await self.wait { probe.snapshot.entered == 1 }
            let middleCompletion = Completion()
            let middle = Task {
                let result = await preparation.prepare(query: "ordinary", entries: rows, options: .init())
                middleCompletion.finished = true
                return result
            }
            second = middle
            try await self.wait { probe.snapshot.requested == 2 }
            let last = Task { await preparation.prepare(query: "message", entries: rows, options: .init()) }
            latest = last
            try await self.wait { middleCompletion.finished }
            let replaced = await middle.value
            #expect(replaced.status == .superseded)
            #expect(probe.snapshot.entered == 1 && probe.snapshot.maximumLeases == 1)
            await gate.releaseAll()
            let initial = await first.value
            let current = await last.value
            #expect(initial.status == .completed && current.status == .completed)
            #expect(current.matches == rows.map { .init(entryId: $0.id, section: .message(0), occurrence: 0) })
            #expect(probe.snapshot.entered == 2 && probe.snapshot.completed == 2 && probe.snapshot.leases == 0)
        } catch {
            first.cancel(); second?.cancel(); latest?.cancel()
            await gate.releaseAll()
            _ = await first.value
            if let second { _ = await second.value }
            if let latest { _ = await latest.value }
            throw error
        }
    }
    @Test func canceledPendingCannotRemoveItsReplacement() async throws {
        let preparation = TranscriptFindPreparation()
        let gate = FindWorkerGate()
        let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
        preparation.probe = probe
        let rows = self.rows()
        let first = Task { await preparation.prepare(query: "needle", entries: rows, options: .init()) }
        var second: Task<TranscriptFindPreparation.Result, Never>?
        var latest: Task<TranscriptFindPreparation.Result, Never>?
        do {
            try await self.wait { probe.snapshot.entered == 1 }
            let oldCompletion = Completion()
            let old = Task {
                let result = await preparation.prepare(query: "ordinary", entries: rows, options: .init())
                oldCompletion.finished = true
                return result
            }
            second = old
            try await self.wait { probe.snapshot.requested == 2 }
            old.cancel()
            let current = Task { await preparation.prepare(query: "message", entries: rows, options: .init()) }
            latest = current
            try await self.wait { oldCompletion.finished }
            let canceled = await old.value
            #expect(canceled.status == .canceled || canceled.status == .superseded)
            try await self.wait { probe.snapshot.requested == 3 }
            #expect(probe.snapshot.entered == 1)
            await gate.releaseAll()
            _ = await first.value
            let result = await current.value
            #expect(result.status == .completed && result.matches.count == 3)
            #expect(probe.snapshot.completed == 2 && probe.snapshot.maximumLeases == 1 && probe.snapshot.leases == 0)
        } catch {
            first.cancel(); second?.cancel(); latest?.cancel()
            await gate.releaseAll()
            _ = await first.value
            if let second { _ = await second.value }
            if let latest { _ = await latest.value }
            throw error
        }
    }
    func request(_ owner: TranscriptFindPreparation, query: String, rows: [TranscriptEntry], completion: Completion? = nil) -> Task<TranscriptFindPreparation.Result, Never> {
        Task {
            let result = await owner.prepare(query: query, entries: rows, options: .init())
            completion?.finished = true
            return result
        }
    }
    @Test func canceledPendingAndReleasedExternalOwnerDrainAcceptedWork() async throws {
        var preparation: TranscriptFindPreparation? = TranscriptFindPreparation()
        let gate = FindWorkerGate()
        let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
        preparation?.probe = probe
        let rows = self.rows()
        let first = self.request(try #require(preparation), query: "needle", rows: rows)
        var pending: Task<TranscriptFindPreparation.Result, Never>?
        do {
            try await self.wait { probe.snapshot.entered == 1 }
            let pendingCompletion = Completion()
            let last = self.request(try #require(preparation), query: "message", rows: rows,
                                    completion: pendingCompletion)
            pending = last
            try await self.wait { probe.snapshot.requested == 2 }
            last.cancel()
            try await self.wait { pendingCompletion.finished }
            let canceled = await last.value
            #expect(canceled.status == .canceled)
            preparation = nil
            #expect(probe.snapshot.entered == 1 && probe.snapshot.leases == 1)
            await gate.releaseAll()
            let completed = await first.value
            #expect(completed.status == .completed && completed.matches.count == 3)
            #expect(probe.snapshot.completed == 1 && probe.snapshot.leases == 0)
        } catch {
            first.cancel(); pending?.cancel()
            await gate.releaseAll()
            _ = await first.value
            if let pending { _ = await pending.value }
            throw error
        }
    }
}
#endif
