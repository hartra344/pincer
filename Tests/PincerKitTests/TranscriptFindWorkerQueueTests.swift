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
    func wait(_ predicate: () -> Bool) async throws {
        while !predicate() {
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
            let middle = Task { await preparation.prepare(query: "ordinary", entries: rows, options: .init()) }
            second = middle
            try await self.wait { probe.snapshot.requested == 2 }
            let last = Task { await preparation.prepare(query: "message", entries: rows, options: .init()) }
            latest = last
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
            let old = Task { await preparation.prepare(query: "ordinary", entries: rows, options: .init()) }
            second = old
            try await self.wait { probe.snapshot.requested == 2 }
            old.cancel()
            let current = Task { await preparation.prepare(query: "message", entries: rows, options: .init()) }
            latest = current
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
    func request(_ owner: TranscriptFindPreparation, query: String, rows: [TranscriptEntry]) -> Task<TranscriptFindPreparation.Result, Never> {
        Task { await owner.prepare(query: query, entries: rows, options: .init()) }
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
            let last = self.request(try #require(preparation), query: "message", rows: rows)
            pending = last
            try await self.wait { probe.snapshot.requested == 2 }
            last.cancel()
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
