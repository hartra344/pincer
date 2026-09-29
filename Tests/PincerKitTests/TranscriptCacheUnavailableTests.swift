import Foundation
import Testing
@testable import PincerKit

/// A transient read failure never deletes the cache (#199); only real content problems do.
@Suite("Transcript cache unavailable vs corrupt", .serialized)
struct TranscriptCacheUnavailableTests {
    let gateway = UUID()
    let key = "agent:main:main"

    func seed(_ temp: TempDir, count: Int = 400) async throws -> (url: URL, items: [ChatItem]) {
        let items = V8.items(count)
        await V8.save(V8.snapshot(items), self.gateway, self.key, temp.url)
        return (V8.manifestURL(self.gateway, self.key, temp.url), items)
    }

    func quarantined(_ temp: TempDir) throws -> Set<String> {
        temp.contents(of: try #require(TranscriptCache.quarantineDirectory(gatewayId: self.gateway, root: temp.url)))
    }

    func isUnavailable(_ outcome: TranscriptCache.LoadOutcome) -> Bool {
        if case .unavailable = outcome { true } else { false }
    }

    func isCorrupt(_ outcome: TranscriptCache.LoadOutcome) -> Bool {
        if case .corrupt = outcome { true } else { false }
    }

    static func chmod(_ url: URL, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: unavailable

    @Test func unreadableManifestIsUnavailableAndKept() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, items) = try await self.seed(temp)
        let bytes = try Data(contentsOf: url)
        Self.chmod(url, 0o000)
        defer { Self.chmod(url, 0o644) }
        try #require(!FileManager.default.isReadableFile(atPath: url.path), "running as root; chmod can't deny reads")

        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isUnavailable(outcome) && !outcome.discarded, "\(outcome)")
        #expect(try self.quarantined(temp).isEmpty)
        Self.chmod(url, 0o644)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!V8.segmentFiles(url).isEmpty && FileManager.default.fileExists(atPath: url.appendingPathExtension("meta").path))

        let (back, again) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(again == .loaded && back?.items == items)
    }

    @Test func unreadableSegmentIsUnavailableAndKept() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, items) = try await self.seed(temp)
        let segment = V8.segmentsDirectory(url).appending(path: try #require(try V8.referenced(url).first))
        Self.chmod(segment, 0o000)
        defer { Self.chmod(segment, 0o644) }
        try #require(!FileManager.default.isReadableFile(atPath: segment.path), "running as root; chmod can't deny reads")

        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isUnavailable(outcome) && !outcome.discarded, "\(outcome)")
        #expect(try self.quarantined(temp).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        Self.chmod(segment, 0o644)
        let (back, again) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(again == .loaded && back?.items == items)
    }

    /// The pre-v8 behaviour: an unreadable legacy single file used to be quarantined as corrupt.
    @Test func unreadableLegacyFileIsUnavailableNotQuarantined() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let url = V8.manifestURL(self.gateway, self.key, temp.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TranscriptCacheSegmentsTests.legacyV7(V8.items(20)).write(to: url)
        Self.chmod(url, 0o000)
        defer { Self.chmod(url, 0o644) }
        try #require(!FileManager.default.isReadableFile(atPath: url.path), "running as root; chmod can't deny reads")

        let (_, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(self.isUnavailable(outcome), "\(outcome)")
        #expect(try self.quarantined(temp).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unavailableIsNotDiscarded() {
        #expect(!TranscriptCache.LoadOutcome.unavailable("busy").discarded)
    }

    // MARK: corrupt

    @Test func corruptManifestIsQuarantined() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        try Data("{\"version\":8,".utf8).write(to: url)
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isCorrupt(outcome) && outcome.discarded, "\(outcome)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: V8.segmentsDirectory(url).path))
        #expect(!(try self.quarantined(temp)).isEmpty)
    }

    @Test func emptyManifestIsCorrupt() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        try Data().write(to: url)
        let (_, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(self.isCorrupt(outcome), "\(outcome)")
    }

    @Test func missingSegmentIsCorrupt() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        let segment = V8.segmentsDirectory(url).appending(path: try #require(try V8.referenced(url).last))
        try FileManager.default.removeItem(at: segment)
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isCorrupt(outcome), "\(outcome)")
        #expect(!(try self.quarantined(temp)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("meta").path))
    }

    @Test func garbageSegmentIsCorrupt() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        let segment = V8.segmentsDirectory(url).appending(path: try #require(try V8.referenced(url).first))
        try Data("not json \u{00}".utf8).write(to: segment)
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isCorrupt(outcome), "\(outcome)")
        #expect(!(try self.quarantined(temp)).isEmpty)
    }

    @Test func segmentCountMismatchIsCorrupt() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        var manifest = try V8.manifest(url)
        var segments = try #require(manifest["segments"] as? [[String: Any]])
        segments[0]["count"] = (segments[0]["count"] as? Int ?? 0) + 1
        manifest["segments"] = segments
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let (_, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(self.isCorrupt(outcome), "\(outcome)")
    }

    @Test func futureManifestVersionIsDiscarded() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let (url, _) = try await self.seed(temp)
        var manifest = try V8.manifest(url)
        manifest["version"] = TranscriptCache.Snapshot.currentVersion + 1
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && outcome == .future(version: TranscriptCache.Snapshot.currentVersion + 1) && outcome.discarded)
    }
}
