import Foundation
import Testing
@testable import PincerKit

/// The search index is per (cache root, Gateway), and tests never touch `PINCER_CACHE_DIR`, so
/// they're safe in parallel. Waiting is by `flush`/`shutdown`, not by sleeping.
@Suite("Cache root isolation")
struct CacheIsolationTests {
    static func snapshot(_ id: String, _ text: String) -> TranscriptCache.Snapshot {
        var item = ChatItem(id: id, role: .user, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: 1))
        item.transcriptId = id
        return TranscriptCache.Snapshot(items: [item], complete: true)
    }

    @Test func sameGatewayUnderTwoRootsGetsTwoIndexes() async throws {
        let (a, b) = (TempDir(), TempDir())
        defer { a.remove(); b.remove() }
        let gateway = UUID()
        await TranscriptCache.save(Self.snapshot("a1", "aardvark"), gatewayId: gateway, sessionKey: "s", root: a.url)
        await TranscriptCache.save(Self.snapshot("b1", "buffalo"), gatewayId: gateway, sessionKey: "s", root: b.url)
        let indexA = MessageIndex.shared(gatewayId: gateway, root: a.url)
        let indexB = MessageIndex.shared(gatewayId: gateway, root: b.url)
        #expect(indexA !== indexB)
        #expect(indexA === MessageIndex.shared(gatewayId: gateway, root: a.url))
        let urlA = try #require(MessageIndex.url(gatewayId: gateway, root: a.url))
        let urlB = try #require(MessageIndex.url(gatewayId: gateway, root: b.url))
        #expect(urlA != urlB && a.exists(urlA) && b.exists(urlB))
        #expect(try await indexA.search("aardvark").count == 1)
        #expect(try await indexA.search("buffalo").isEmpty)
        #expect(try await indexB.search("buffalo").count == 1)
        #expect(try await indexB.search("aardvark").isEmpty)
        await TranscriptCache.shutdown(root: a.url)
        await TranscriptCache.shutdown(root: b.url)
    }

    @Test func discardingOneRootLeavesTheOtherWorking() async throws {
        let (a, b) = (TempDir(), TempDir())
        defer { a.remove(); b.remove() }
        let gateway = UUID()
        await TranscriptCache.save(Self.snapshot("a1", "aardvark"), gatewayId: gateway, sessionKey: "s", root: a.url)
        await TranscriptCache.save(Self.snapshot("b1", "aardvark"), gatewayId: gateway, sessionKey: "s", root: b.url)
        let indexB = MessageIndex.shared(gatewayId: gateway, root: b.url)
        TranscriptCache.removeAll(gatewayId: gateway, root: a.url)
        await MessageIndex.flush(gatewayId: gateway, root: a.url)
        #expect(MessageIndex.shared(gatewayId: gateway, root: b.url) === indexB)
        #expect(try await indexB.search("aardvark").count == 1)
        let urlA = try #require(MessageIndex.url(gatewayId: gateway, root: a.url))
        #expect(!a.exists(urlA))
        // A's index is recreated empty on demand.
        #expect(try await MessageIndex.shared(gatewayId: gateway, root: a.url).search("aardvark").isEmpty)
        await TranscriptCache.shutdown(root: a.url)
        await TranscriptCache.shutdown(root: b.url)
    }

    @Test func deletingOneRootDoesNotStallAnother() {
        let (a, b) = (TempDir(), TempDir())
        defer { a.remove(); b.remove() }
        let gateway = UUID()
        var duringA: MessageIndex?
        var duringB: MessageIndex?
        MessageIndex.whileDeleting(root: a.url) {
            duringA = MessageIndex.shared(gatewayId: gateway, root: a.url)
            duringB = MessageIndex.shared(gatewayId: gateway, root: b.url)
        }
        #expect(duringA !== MessageIndex.shared(gatewayId: gateway, root: a.url), "inert while a is being deleted")
        #expect(duringB === MessageIndex.shared(gatewayId: gateway, root: b.url), "b is unaffected")
    }

    @Test func removingAGatewayPermanentlyRetiresItEverywhere() async throws {
        let (a, b) = (TempDir(), TempDir())
        defer { a.remove(); b.remove() }
        let gateway = UUID()
        await TranscriptCache.save(Self.snapshot("a1", "aardvark"), gatewayId: gateway, sessionKey: "s", root: a.url)
        await TranscriptCache.save(Self.snapshot("b1", "aardvark"), gatewayId: gateway, sessionKey: "s", root: b.url)
        let indexB = MessageIndex.shared(gatewayId: gateway, root: b.url)
        TranscriptCache.removeAll(gatewayId: gateway, permanently: true, root: a.url)
        #expect(MessageIndex.isDiscardedPermanently(gatewayId: gateway))
        #expect(MessageIndex.shared(gatewayId: gateway, root: b.url) !== indexB)
        #expect(try await indexB.search("aardvark").isEmpty)
        await TranscriptCache.save(Self.snapshot("a2", "zebra"), gatewayId: gateway, sessionKey: "t", root: b.url)
        #expect(try await MessageIndex.shared(gatewayId: gateway, root: b.url).search("zebra").isEmpty)
    }

    // MARK: Awaited flush and shutdown

    @Test func flushWaitsForIndexingToFinish() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let snapshots = (0..<20).map { Self.snapshot("m\($0)", "marmot \($0)") }
        let saves = Task {
            await withTaskGroup(of: Void.self) { group in
                for (i, snapshot) in snapshots.enumerated() {
                    group.addTask { await TranscriptCache.save(snapshot, gatewayId: gateway, sessionKey: "k\(i)", root: temp.url) }
                }
            }
        }
        await saves.value
        await TranscriptCache.flush(gatewayId: gateway, root: temp.url)
        #expect(try await MessageIndex.shared(gatewayId: gateway, root: temp.url).search("marmot").count == 20)
        await TranscriptCache.shutdown(root: temp.url)
    }

    @Test func flushWaitsForInFlightReconcile() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        for i in 0..<10 {
            await TranscriptCache.save(Self.snapshot("m\(i)", "lemur \(i)"), gatewayId: gateway, sessionKey: "k\(i)", root: temp.url)
        }
        await TranscriptCache.shutdown(root: temp.url)
        try FileManager.default.removeItem(at: #require(MessageIndex.url(gatewayId: gateway, root: temp.url)))
        let index = MessageIndex.shared(gatewayId: gateway, root: temp.url)
        let running = Task { await index.reconcile(sessionKeys: (0..<10).map { "k\($0)" }) }
        await MessageIndex.flush(gatewayId: gateway, root: temp.url)
        await running.value
        #expect(try await index.search("lemur").count == 10)
        await TranscriptCache.shutdown(root: temp.url)
    }

    @Test func shutdownClosesAndForgetsEveryIndexUnderTheRoot() async throws {
        let (a, b) = (TempDir(), TempDir())
        defer { a.remove(); b.remove() }
        let (g1, g2) = (UUID(), UUID())
        await TranscriptCache.save(Self.snapshot("x", "okapi"), gatewayId: g1, sessionKey: "s", root: a.url)
        await TranscriptCache.save(Self.snapshot("y", "okapi"), gatewayId: g2, sessionKey: "s", root: a.url)
        await TranscriptCache.save(Self.snapshot("z", "okapi"), gatewayId: g1, sessionKey: "s", root: b.url)
        let old1 = MessageIndex.shared(gatewayId: g1, root: a.url)
        let otherRoot = MessageIndex.shared(gatewayId: g1, root: b.url)
        await MessageIndex.shutdown(root: a.url)
        #expect(MessageIndex.shared(gatewayId: g1, root: a.url) !== old1)
        #expect(MessageIndex.shared(gatewayId: g1, root: b.url) === otherRoot)
        // The data is on disk: a fresh index over the closed file still finds it.
        #expect(try await MessageIndex.shared(gatewayId: g2, root: a.url).search("okapi").count == 1)
        await TranscriptCache.shutdown(root: a.url)
        await TranscriptCache.shutdown(root: b.url)
    }

    @Test func flushAfterDiscardWaitsForTheClose() async {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        await TranscriptCache.save(Self.snapshot("x", "yak"), gatewayId: gateway, sessionKey: "s", root: temp.url)
        TranscriptCache.removeAll(gatewayId: gateway, root: temp.url)
        await MessageIndex.flush(gatewayId: gateway, root: temp.url)
        // Nothing left open on the deleted files: the folder can be recreated cleanly.
        await TranscriptCache.save(Self.snapshot("y", "yak"), gatewayId: gateway, sessionKey: "s", root: temp.url)
        await TranscriptCache.shutdown(root: temp.url)
    }

    // MARK: Quarantine order

    @Test func quarantineStampsSortInCreationOrderEvenInTheSameMillisecond() {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let stamps = (0..<50).map { _ in TranscriptCache.nextQuarantineStamp(now: frozen) }
        #expect(stamps == stamps.sorted() && Set(stamps).count == 50)
        let parsed = stamps.compactMap { TranscriptCache.quarantineOrder("chat-\($0).json") }
        #expect(parsed.count == 50 && parsed.allSatisfy { $0.ms == 1_700_000_000_000 })
    }

    @Test func trimKeepsTheNewestByStampNotByFileDate() throws {
        let temp = TempDir()
        defer { temp.remove() }
        let names = (0..<8).map { String(format: "chat-%015ld-%08ld.json", 1000, $0) }
        for name in names.shuffled() {
            try Data(name.utf8).write(to: temp.url.appending(path: name))
        }
        // Old-style names, older than anything stamped.
        try Data().write(to: temp.url.appending(path: "chat-9999999999999.json"))
        TranscriptCache.trimQuarantine(temp.url)
        #expect(temp.contents(of: temp.url) == Set(names.suffix(TranscriptCache.maxQuarantined)))
    }
}
