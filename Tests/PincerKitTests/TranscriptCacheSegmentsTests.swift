import Foundation
import Testing
@testable import PincerKit

/// v8 segmented storage: manifest + segments, migration from the v7 single file, round trips.
@Suite("Transcript cache segments", .serialized)
struct TranscriptCacheSegmentsTests {
    let gateway = UUID()
    let key = "agent:main:main"

    @Test func currentVersionIsEight() {
        #expect(TranscriptCache.Snapshot.currentVersion == 8)
        #expect(TranscriptCache.migrations[7] != nil)
    }

    @Test func roundTripWritesManifestAndSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(700)
        await V8.save(V8.snapshot(items, complete: false, activityMs: 99, retained: true), self.gateway, self.key, temp.url)

        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let manifest = try V8.manifest(url)
        #expect(manifest["version"] as? Int == 8 && manifest["complete"] as? Bool == false)
        #expect(manifest["retained"] as? Bool == true && manifest["activityMs"] as? Double == 99)
        #expect(manifest["items"] == nil && manifest["token"] is String)
        let segments = try #require(manifest["segments"] as? [[String: Any]])
        #expect(segments.count > 1 && segments.compactMap { $0["count"] as? Int }.reduce(0, +) == items.count)
        #expect(segments.allSatisfy { ($0["count"] as? Int ?? 0) <= 256 })
        #expect(segments.first?["firstId"] as? String == items.first?.id && segments.last?["lastId"] as? String == items.last?.id)
        #expect(V8.segmentFiles(url) == Set(try V8.referenced(url)))

        let (loaded, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .loaded)
        #expect(loaded?.items == items && loaded?.complete == false && loaded?.retained == true && loaded?.activityMs == 99)
    }

    @Test func manifestIsSmall() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await V8.save(V8.snapshot(V8.items(5000)), self.gateway, self.key, temp.url)
        #expect(V8.size(V8.manifestURL(self.gateway, self.key, temp.url)) < 64 * 1024)
    }

    @Test func emptyTranscriptRoundTrips() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await V8.save(V8.snapshot([]), self.gateway, self.key, temp.url)
        let (loaded, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .loaded && loaded?.items.isEmpty == true)
    }

    @Test func segmentBoundariesAreContentDefinedAcrossAppends() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(2000)
        await V8.save(V8.snapshot(Array(items[..<1990])), self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let before = try V8.referenced(url)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        let after = try V8.referenced(url)
        // Everything but the last (open) segment is reused under the same name.
        #expect(after.count >= before.count)
        #expect(Array(after.prefix(before.count - 1)) == Array(before.dropLast()))
    }

    // MARK: v7 → v8

    static func legacyV7(_ items: [ChatItem]) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TranscriptCache.Snapshot(version: 7, items: items, complete: true, activityMs: 42))) as? [String: Any])
        json["version"] = 7
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func decodeLiteralV7MigratesInMemory() throws {
        let items = V8.items(30)
        let (snapshot, outcome) = TranscriptCache.decode(try Self.legacyV7(items))
        #expect(outcome == .migrated(from: 7) && !outcome.discarded)
        #expect(snapshot?.items == items && snapshot?.version == TranscriptCache.Snapshot.currentVersion)
    }

    @Test func v7FileOnDiskMigratesToManifestAndSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let items = V8.items(600)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.legacyV7(items).write(to: url)
        try JSONEncoder().encode(TranscriptCache.Meta(complete: true, activityMs: 42, version: 7)).write(to: url.appendingPathExtension("meta"))

        let (loaded, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .migrated(from: 7))
        #expect(loaded?.items == items)

        // The migration is saved back as v8: a small manifest plus segments, items identical.
        var manifest: [String: Any] = [:]
        for _ in 0..<200 {
            manifest = (try? V8.manifest(url)) ?? [:]
            if manifest["version"] as? Int == 8 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(manifest["version"] as? Int == 8 && manifest["items"] == nil)
        #expect(!V8.segmentFiles(url).isEmpty)
        let (again, second) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(second == .loaded && again?.items == items)
    }

    @Test func removeDeletesSegmentsSidecarAndManifest() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await V8.save(V8.snapshot(V8.items(300)), self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        #expect(!V8.segmentFiles(url).isEmpty)
        await TranscriptCache.remove(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: V8.segmentsDirectory(url).path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("meta").path))
    }

    @Test func removeAllAndDiskUsageCoverSegments() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await V8.save(V8.snapshot(V8.items(400)), self.gateway, self.key, temp.url)
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        let segmentBytes = V8.segmentFiles(url).reduce(0) { $0 + V8.size(V8.segmentsDirectory(url).appending(path: $1)) }
        #expect(await TranscriptCache.diskUsage(root: temp.url) >= Int64(segmentBytes))
        TranscriptCache.removeAll(gatewayId: self.gateway, root: temp.url)
        #expect(!FileManager.default.fileExists(atPath: V8.segmentsDirectory(url).path))
    }
}
