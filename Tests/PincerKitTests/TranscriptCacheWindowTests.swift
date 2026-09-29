import Foundation
import Testing
@testable import PincerKit

/// Windowed saves and paged reads of the segmented transcript cache (#198, #199).
@Suite("Transcript cache windows", .serialized)
struct TranscriptCacheWindowTests {
    let gateway = UUID()
    let key = "agent:main:window"
    typealias Cache = TranscriptCache

    func loadAll(_ root: URL) async -> Cache.Snapshot? {
        await Cache.load(gatewayId: self.gateway, sessionKey: self.key, root: root)
    }

    @Test func windowSaveKeepsOlderSegmentsUntouched() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(3000)
        await V8.save(V8.snapshot(items, complete: true), self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let before = try V8.referenced(url)
        let oldest = try Data(contentsOf: V8.segmentsDirectory(url).appending(path: before[0]))

        let extra = V8.items(1, from: 3000)
        let window = Array(items[2200...]) + extra
        let result = await Cache.saveReturningStats(
            V8.snapshot(window, complete: false), gatewayId: self.gateway, sessionKey: self.key, keepingOlder: true, root: temp.url)
        #expect(!result.unchanged && result.bytesWritten > 0 && result.filesWritten <= 6)

        let after = try V8.referenced(url)
        #expect(after.prefix(20) == before.prefix(20), "older segments are reused, not rewritten")
        #expect(try Data(contentsOf: V8.segmentsDirectory(url).appending(path: after[0])) == oldest)
        let loaded = try #require(await self.loadAll(temp.url))
        #expect(loaded.items == items + extra)
        #expect(loaded.complete, "complete stays the stored one")
        #expect(V8.segmentFiles(url) == Set(after))
    }

    @Test func identicalWindowSaveWritesNothing() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(1500)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        let window = Array(items[1000...])
        let first = await Cache.saveReturningStats(
            V8.snapshot(window), gatewayId: self.gateway, sessionKey: self.key, keepingOlder: true, root: temp.url)
        #expect(first.unchanged, "a window equal to the stored tail changes nothing")
        let again = await Cache.saveReturningStats(
            V8.snapshot(window), gatewayId: self.gateway, sessionKey: self.key, keepingOlder: true, root: temp.url)
        #expect(again.unchanged && again.bytesWritten == 0)
        #expect(await self.loadAll(temp.url)?.items == items)
    }

    @Test func windowWithAGapReplacesTheTranscript() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await V8.save(V8.snapshot(V8.items(1000)), self.gateway, self.key, temp.url)
        let far = V8.items(100, from: 5000)
        await Cache.save(V8.snapshot(far, complete: false), gatewayId: self.gateway, sessionKey: self.key,
                         keepingOlder: true, root: temp.url)
        let loaded = try #require(await self.loadAll(temp.url))
        #expect(loaded.items == far && !loaded.complete)
    }

    @Test func windowWithoutStoredTranscriptIsAPlainSave() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let window = V8.items(50)
        await Cache.save(V8.snapshot(window, complete: false), gatewayId: self.gateway, sessionKey: self.key,
                         keepingOlder: true, root: temp.url)
        let loaded = try #require(await self.loadAll(temp.url))
        #expect(loaded.items == window && !loaded.complete)
    }

    @Test func windowSaveIsIndexedAsTheWholeTranscript() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(1200)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        let extra = V8.items(1, from: 1200)
        await Cache.save(V8.snapshot(Array(items[900...]) + extra), gatewayId: self.gateway, sessionKey: self.key,
                         keepingOlder: true, root: temp.url)
        await Cache.flush(gatewayId: self.gateway, root: temp.url)
        let index = MessageIndex.shared(gatewayId: self.gateway, root: temp.url)
        let hits = try await index.search("question 0")
        #expect(!hits.isEmpty, "messages older than the window stay searchable")
    }

    @Test func loadOlderPagesAcrossSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(1000)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)

        let page = await Cache.loadOlder(gatewayId: self.gateway, sessionKey: self.key, before: items[900].id, limit: 100,
                                         root: temp.url)
        #expect(page.items == Array(items[800..<900]) && !page.reachedStart && page.outcome == .loaded)

        var cursor = items[900].id
        var collected: [ChatItem] = []
        var reached = false
        for _ in 0..<50 where !reached {
            let next = await Cache.loadOlder(gatewayId: self.gateway, sessionKey: self.key, before: cursor, limit: 130,
                                             root: temp.url)
            collected = next.items + collected
            reached = next.reachedStart
            guard let first = next.items.first else { break }
            cursor = first.id
        }
        #expect(reached && collected == Array(items[..<900]))

        let exact = await Cache.loadOlder(gatewayId: self.gateway, sessionKey: self.key, before: items[10].id, limit: 10,
                                          root: temp.url)
        #expect(exact.items == Array(items[..<10]) && exact.reachedStart)
        let start = await Cache.loadOlder(gatewayId: self.gateway, sessionKey: self.key, before: items[0].id, limit: 10,
                                          root: temp.url)
        #expect(start.items.isEmpty && start.reachedStart)
        let unknown = await Cache.loadOlder(gatewayId: self.gateway, sessionKey: self.key, before: "nope", limit: 10,
                                            root: temp.url)
        #expect(unknown.items.isEmpty && unknown.outcome == .missing)
        let none = await Cache.loadOlder(gatewayId: UUID(), sessionKey: "x", before: "a", limit: 10, root: temp.url)
        #expect(none.outcome == .missing)
    }

    @Test func loadNewestReadsTheTailAndPrimesTheNextWindowSave() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(5000)
        await V8.save(V8.snapshot(items, complete: false, retained: true), self.gateway, self.key, temp.url)

        let newest = await Cache.loadNewest(gatewayId: self.gateway, sessionKey: self.key, limit: 700, root: temp.url)
        #expect(newest.items == Array(items.suffix(700)) && !newest.complete && newest.outcome == .loaded)
        let all = await Cache.loadNewest(gatewayId: self.gateway, sessionKey: self.key, limit: 10000, root: temp.url)
        #expect(all.items == items)
        let none = await Cache.loadNewest(gatewayId: UUID(), sessionKey: "x", limit: 5, root: temp.url)
        #expect(none.items.isEmpty && none.outcome == .missing)

        // A fresh process (nothing remembered) that loaded only the tail saves a window cheaply.
        await Cache.shutdown(root: temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let before = try V8.referenced(url)
        let extra = V8.items(1, from: 5000)
        let result = await Cache.saveReturningStats(
            V8.snapshot(newest.items + extra, complete: false, retained: true), gatewayId: self.gateway,
            sessionKey: self.key, keepingOlder: true, root: temp.url)
        #expect(result.bytesWritten < 200_000 && result.filesWritten <= 5, "wrote \(result.bytesWritten) bytes")
        #expect(try V8.referenced(url).prefix(before.count - 20) == before.prefix(before.count - 20))
        #expect(await self.loadAll(temp.url)?.items == items + extra)
    }
}

extension TranscriptCacheWindowTests {
    @Test func tailAppendDoesNotDecodeOlderSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(6000)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        await Cache.flush(gatewayId: self.gateway, root: temp.url)

        let window = Array(items[4800...])
        let before = Cache.segmentDecodeCount(root: temp.url)
        let extra = V8.items(1, from: 6000)
        let result = await Cache.saveReturningStats(
            V8.snapshot(window + extra), gatewayId: self.gateway, sessionKey: self.key, keepingOlder: true, root: temp.url)
        await Cache.flush(gatewayId: self.gateway, root: temp.url)
        #expect(!result.unchanged)
        #expect(Cache.segmentDecodeCount(root: temp.url) - before <= 2, "decoded \(Cache.segmentDecodeCount(root: temp.url) - before) segments")

        let index = MessageIndex.shared(gatewayId: self.gateway, root: temp.url)
        #expect(index.lastIndexStats.path == .tail)
        #expect(!(try await index.search("question 0")).isEmpty)
        #expect(await self.loadAll(temp.url)?.items == items + extra)
    }
}

extension TranscriptCacheWindowTests {
    @Test func windowSaveThatDropsOldestSegmentsIsNoLongerComplete() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(20500)
        await V8.save(V8.snapshot(items, complete: true), self.gateway, self.key, temp.url)
        let extra = V8.items(1, from: 20500)
        await Cache.save(V8.snapshot(Array(items[19000...]) + extra, complete: true), gatewayId: self.gateway,
                         sessionKey: self.key, keepingOlder: true, root: temp.url)
        let loaded = try #require(await self.loadAll(temp.url))
        #expect(loaded.items.count <= Cache.maxItems + Cache.maxSegmentItems && loaded.items.last?.id == extra[0].id)
        #expect(!loaded.complete && loaded.retained)
        let meta = try #require(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(!meta.complete)
    }

    @Test func imageBase64ChangeIsSaved() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        func item(_ data: String) -> ChatItem {
            ChatItem(id: "img", role: .assistant,
                     blocks: [.image(ImageRef(artifactId: "art", base64: data, url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil))],
                     timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        }
        await V8.save(V8.snapshot([item("AAAA")]), self.gateway, self.key, temp.url)
        let result = await V8.save(V8.snapshot([item("BBBB")]), self.gateway, self.key, temp.url)
        #expect(!result.unchanged)
        let loaded = try #require(await self.loadAll(temp.url))
        #expect(loaded.items == [item("BBBB")])
    }
}
