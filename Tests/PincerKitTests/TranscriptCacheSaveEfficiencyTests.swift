import Foundation
import Testing
@testable import PincerKit

/// A save writes only what changed (#199).
@Suite("Transcript cache save efficiency", .serialized)
struct TranscriptCacheSaveEfficiencyTests {
    let gateway = UUID()
    let key = "agent:main:big"

    @Test func appendOneItemWritesAFractionOfAFullSave() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(20000)
        let full = await V8.save(V8.snapshot(Array(items.dropLast())), self.gateway, self.key, temp.url)
        #expect(!full.unchanged && full.bytesWritten > 1_000_000)

        let append = await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        #expect(!append.unchanged && append.bytesWritten > 0)
        #expect(append.bytesWritten * 20 < full.bytesWritten, "appended \(append.bytesWritten) vs full \(full.bytesWritten)")
        #expect(append.filesWritten <= 4)

        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        #expect(V8.segmentFiles(url) == Set(try V8.referenced(url)), "stale segments are deleted")
    }

    @Test func identicalSaveWritesNothingAndKeepsTheMtime() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let snapshot = V8.snapshot(V8.items(3000))
        await V8.save(snapshot, self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let mtime = V8.mtime(url)
        let manifest = try Data(contentsOf: url)
        try await Task.sleep(for: .milliseconds(30))

        let again = await V8.save(snapshot, self.gateway, self.key, temp.url)
        #expect(again.unchanged && again.bytesWritten == 0 && again.filesWritten == 0)
        #expect(V8.mtime(url) == mtime)
        #expect(try Data(contentsOf: url) == manifest)
    }

    @Test func changedFlagsAloneRewriteOnlyTheManifest() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(3000)
        let first = await V8.save(V8.snapshot(items, complete: false), self.gateway, self.key, temp.url)
        let second = await V8.save(V8.snapshot(items, complete: true), self.gateway, self.key, temp.url)
        #expect(!second.unchanged && second.bytesWritten < first.bytesWritten / 10)
        let third = await V8.save(V8.snapshot(items, complete: true, activityMs: 8), self.gateway, self.key, temp.url)
        #expect(!third.unchanged)
        let fourth = await V8.save(V8.snapshot(items, complete: true, activityMs: 8, retained: true), self.gateway, self.key, temp.url)
        #expect(!fourth.unchanged)
    }

    @Test func prependingOlderItemsRewritesOnlyTheNewSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let all = V8.items(20000)
        let full = await V8.save(V8.snapshot(Array(all[200...])), self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let before = Set(try V8.referenced(url))

        let prepend = await V8.save(V8.snapshot(all), self.gateway, self.key, temp.url)
        #expect(!prepend.unchanged)
        #expect(prepend.bytesWritten * 10 < full.bytesWritten, "prepended \(prepend.bytesWritten) vs full \(full.bytesWritten)")
        let after = Set(try V8.referenced(url))
        #expect(after.intersection(before).count >= before.count - 2, "existing segments stay byte-identical")
        #expect(V8.segmentFiles(url) == after)
    }

    @Test func editingTheLastItemRewritesOneSegment() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var items = V8.items(5000)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        items[items.count - 1].blocks = [.text("edited while streaming")]
        let edit = await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        #expect(!edit.unchanged && edit.filesWritten <= 3)
        let (loaded, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .loaded && loaded?.items == items)
    }

    @Test func firstSaveAfterRelaunchWritesOnlyChangedSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(6000)
        let full = await V8.save(V8.snapshot(Array(items.dropLast())), self.gateway, self.key, temp.url)
        // A load primes the writer's layout from disk, as after a launch.
        _ = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let append = await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        #expect(append.bytesWritten * 10 < full.bytesWritten)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_BENCH"] == "1"))
    func benchTwentyThousandItemSaveCycle() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(20000)
        let clock = ContinuousClock()
        let start = clock.now
        let full = await V8.save(V8.snapshot(Array(items.dropLast())), self.gateway, self.key, temp.url)
        let mid = clock.now
        let append = await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        print("bench full=\(full.bytesWritten)B in \(mid - start), append=\(append.bytesWritten)B in \(clock.now - mid)")
    }
}
