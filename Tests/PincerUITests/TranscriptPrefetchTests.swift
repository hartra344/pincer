import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@Suite("TranscriptMeasureQueue")
struct TranscriptMeasureQueueTests {
    static func queue(_ count: Int) -> TranscriptMeasureQueue {
        var queue = TranscriptMeasureQueue()
        queue.markAllUnmeasured(count: count)
        return queue
    }

    @Test func startsEmptyAndTracksAllRows() {
        #expect(TranscriptMeasureQueue().isEmpty)
        let queue = Self.queue(100)
        #expect(queue.count == 100 && !queue.isEmpty)
        var none = TranscriptMeasureQueue()
        none.markAllUnmeasured(count: 0)
        #expect(none.isEmpty)
    }

    @Test func nearestFirstAlternatesBelowAndAbove() {
        let queue = Self.queue(100)
        #expect(queue.next(center: 50, window: 0...99, limit: 7) == [50, 49, 51, 48, 52, 47, 53])
    }

    @Test func distanceFromCenterNeverDecreases() {
        var queue = Self.queue(500)
        for row in stride(from: 0, to: 500, by: 3) { queue.markMeasured(row) }
        let picked = queue.next(center: 240, window: 0...499, limit: 200)
        #expect(picked.count == 200)
        #expect(Set(picked).count == 200)
        let distances = picked.map { abs($0 - 240) }
        // Rows on either side of the centre interleave, so allow the one-row skew of below/above pairing.
        for (a, b) in zip(distances, distances.dropFirst()) { #expect(b >= a - 1) }
        #expect(picked.allSatisfy { queue.contains($0) })
    }

    @Test func windowBoundsAreRespected() {
        let queue = Self.queue(1000)
        let picked = queue.next(center: 500, window: 490...510, limit: 1000)
        #expect(picked.count == 21)
        #expect(picked.allSatisfy { (490...510).contains($0) })
        #expect(Set(picked) == Set(490...510))
    }

    @Test func centerOutsideTheWindowIsClamped() {
        let queue = Self.queue(1000)
        #expect(queue.next(center: 0, window: 100...105, limit: 3) == [100, 101, 102])
        #expect(queue.next(center: 999, window: 100...105, limit: 3) == [105, 104, 103])
    }

    @Test func limitZeroOrEmptyQueueYieldsNothing() {
        #expect(Self.queue(10).next(center: 5, window: 0...9, limit: 0).isEmpty)
        #expect(TranscriptMeasureQueue().next(center: 5, window: 0...9, limit: 10).isEmpty)
    }

    @Test func measuredRowsDropOutAndDrainingEmptiesTheQueue() {
        var queue = Self.queue(50)
        var seen: [Int] = []
        while true {
            let batch = queue.next(center: 25, window: 0...49, limit: 6)
            if batch.isEmpty { break }
            for row in batch { queue.markMeasured(row); seen.append(row) }
        }
        #expect(queue.isEmpty && queue.count == 0)
        #expect(Set(seen) == Set(0..<50) && seen.count == 50)
    }

    @Test func rowsOutsideTheWindowStayUnmeasured() {
        var queue = Self.queue(1000)
        for row in queue.next(center: 500, window: 400...600, limit: 10_000) { queue.markMeasured(row) }
        #expect(queue.count == 1000 - 201)
        #expect(queue.next(center: 500, window: 400...600, limit: 10).isEmpty)
        #expect(queue.next(center: 700, window: 600...800, limit: 1) == [700])
    }

    @Test func markUnmeasuredRequeuesARow() {
        var queue = Self.queue(10)
        for row in 0..<10 { queue.markMeasured(row) }
        #expect(queue.isEmpty)
        queue.markUnmeasured(4)
        queue.markUnmeasured(-3)
        #expect(queue.next(center: 0, window: 0...9, limit: 5) == [4])
    }

    @Test func insertShiftsLaterRowsAndQueuesTheNewOnes() {
        var queue = Self.queue(5)
        for row in 0..<5 { queue.markMeasured(row) }
        queue.markUnmeasured(3)
        // A row lands at index 1: the old row 3 is now 4, and index 1 is new.
        queue.insert(rows: IndexSet(integer: 1))
        #expect(Set(queue.next(center: 0, window: 0...9, limit: 10)) == [1, 4])
    }

    @Test func removeShiftsLaterRowsUp() {
        var queue = Self.queue(6)
        for row in 0..<6 { queue.markMeasured(row) }
        queue.markUnmeasured(2)
        queue.markUnmeasured(5)
        queue.remove(rows: IndexSet(integer: 2))
        #expect(Set(queue.next(center: 0, window: 0...9, limit: 10)) == [4])
    }

    @Test func rebuildUsesThePredicate() {
        var queue = Self.queue(10)
        queue.rebuild(count: 20) { $0 % 5 == 0 }
        #expect(Set(queue.next(center: 0, window: 0...19, limit: 100)) == [0, 5, 10, 15])
    }

    @Test func windowIsClampedToTheTranscript() {
        #expect(TranscriptMeasureQueue.window(in: -5..<3, count: 100) == 0...2)
        #expect(TranscriptMeasureQueue.window(in: 90..<130, count: 100) == 90...99)
        #expect(TranscriptMeasureQueue.window(in: 0..<0, count: 100) == nil)
        #expect(TranscriptMeasureQueue.window(in: 0..<10, count: 0) == nil)
        #expect(TranscriptMeasureQueue.screensAhead == 10)
    }

    @Test func nextOnAHugeQueueOnlyTouchesWhatItReturns() {
        let queue = Self.queue(200_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<200 { _ = queue.next(center: 100_000, window: 0...199_999, limit: 8) } }
        #expect(elapsed < PerfBudget.limit(.milliseconds(50)))
    }
}

@MainActor
@Suite("TranscriptLayoutCache", .serialized)
struct TranscriptLayoutCacheTests {
    static let key = "agent:probe:main"

    static func renderer(_ scratch: ScratchDefaults) -> TranscriptRenderer {
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: Self.key)
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: Self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        return TranscriptRenderer(context: context)
    }

    static func row(_ n: Int) -> TranscriptRow {
        var item = ChatItem(id: "m\(n)", role: n % 2 == 0 ? .user : .assistant,
                            blocks: [.text("Message \(n): the quick brown fox jumps over the lazy dog.")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        item.transcriptId = item.id
        return .entry(.user(item))
    }

    @Test func layoutCacheIsBoundedAfterManyRows() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = Self.renderer(scratch)
        let limit = TranscriptRenderer.layoutCacheLimit
        #expect(limit == 800)
        for n in 0..<(limit * 3) {
            _ = renderer.layout(for: Self.row(n), width: 700)
            #expect(renderer.cachedLayoutCount <= limit)
        }
        #expect(renderer.cachedLayoutCount > limit / 2)
    }

    @Test func recentRowsStayCachedAndOldOnesAreRebuilt() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = Self.renderer(scratch)
        let limit = TranscriptRenderer.layoutCacheLimit
        let first = renderer.layout(for: Self.row(0), width: 700)
        for n in 1..<(limit * 2) { _ = renderer.layout(for: Self.row(n), width: 700) }
        let recentRow = Self.row(limit * 2 - 1)
        let recent = renderer.layout(for: recentRow, width: 700)
        #expect(renderer.layout(for: recentRow, width: 700).serial == recent.serial)
        // Row 0 was pushed out, so laying it out again is a fresh build (new serial) with the same size.
        let again = renderer.layout(for: Self.row(0), width: 700)
        #expect(again.serial != first.serial)
        #expect(again.height == first.height)
        #expect(renderer.cachedLayoutCount <= limit)
    }

    @Test func touchingARowKeepsItAcrossEviction() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = Self.renderer(scratch)
        let limit = TranscriptRenderer.layoutCacheLimit
        let hot = Self.row(0)
        let hotSerial = renderer.layout(for: hot, width: 700).serial
        for n in 1..<(limit * 2) {
            _ = renderer.layout(for: Self.row(n), width: 700)
            if n % 50 == 0 { _ = renderer.layout(for: hot, width: 700) }
        }
        #expect(renderer.layout(for: hot, width: 700).serial == hotSerial)
    }

    @Test func resetEmptiesTheCache() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = Self.renderer(scratch)
        for n in 0..<20 { _ = renderer.layout(for: Self.row(n), width: 700) }
        #expect(renderer.cachedLayoutCount == 20)
        renderer.reset()
        #expect(renderer.cachedLayoutCount == 0)
    }
}
