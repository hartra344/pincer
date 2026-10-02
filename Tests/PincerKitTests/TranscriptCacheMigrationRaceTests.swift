import Foundation
import Testing
@testable import PincerKit

@Suite("Transcript cache migration write ordering")
@MainActor
struct TranscriptCacheMigrationRaceTests {
    @Test func unchangedLegacyManifestStillMigratesAndKeepsRefreshMarker() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let sessionKey = "agent:main:main"
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        var oldRow = ChatItem(id: "legacy-row", role: .assistant, blocks: [.text("Keep this cached reply")],
                              timestamp: Date(timeIntervalSince1970: 3))
        oldRow.transcriptId = oldRow.id
        let original = TranscriptCache.Snapshot(items: [oldRow], complete: true, activityMs: 11)
        let manifestURL = try #require(TranscriptCache.file(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        let seed = await writer.write(original, to: manifestURL)
        await writer.drain()
        try #require(seed.modified != nil || seed.unchanged)

        let seededRead = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        #expect(seededRead.version == TranscriptCache.Snapshot.currentVersion)
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let segmentNames = (manifest["segments"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
        try #require(!segmentNames.isEmpty)
        try #require(segmentNames.allSatisfy {
            FileManager.default.isReadableFile(atPath: V8.segmentsDirectory(manifestURL).appendingPathComponent($0).path)
        })
        manifest["version"] = 9
        manifest.removeValue(forKey: "forwardedSenderRefreshPending")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
        let oldMeta = TranscriptCache.Meta(complete: true, activityMs: 11, version: 9, retained: false)
        try JSONEncoder().encode(oldMeta).write(to: manifestURL.appendingPathExtension("meta"), options: .atomic)

        let gate = MigrationWriteGate()
        let restored = await TranscriptCache.read(
            manifestURL, gatewayId: gateway, root: temp.url,
            legacyManifestMigrationWriteObserver: { phase in
                switch phase {
                case .beforeEnqueue: break
                case .finished: await gate.markFinished()
                }
            }, migrationWriter: writer, priority: .utility)
        try #require(restored.outcome == .migrated(from: 9))
        await gate.waitUntilFinished()

        let diskManifest = try #require(try JSONDecoder().decode(TranscriptCache.Manifest.self, from: Data(contentsOf: manifestURL)))
        let migrated = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        #expect(diskManifest.version == TranscriptCache.Snapshot.currentVersion)
        #expect(diskManifest.forwardedSenderRefreshPending)
        #expect(migrated.items.first?.plainText == "Keep this cached reply")
        #expect(migrated.forwardedSenderRefreshPending)
    }

    @Test func delayedLegacyMigrationCannotOverwriteAuthoritativeSenderRefresh() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let sessionKey = "agent:main:main"
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        var oldRow = ChatItem(id: "forwarded", role: .assistant, blocks: [.text("Kiko's message")],
                              timestamp: Date(timeIntervalSince1970: 2))
        oldRow.transcriptId = oldRow.id
        let original = TranscriptCache.Snapshot(items: [oldRow], complete: true, activityMs: 10)
        let manifestURL = try #require(TranscriptCache.file(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        let seed = await writer.write(original, to: manifestURL)
        await writer.drain()
        try #require(seed.modified != nil || seed.unchanged, "the race fixture must first create a readable cache")

        let seededRead = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        #expect(seededRead.version == TranscriptCache.Snapshot.currentVersion)
        #expect(seededRead.items.first?.sender == nil)
        try #require(FileManager.default.isReadableFile(atPath: manifestURL.path))
        var oldManifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let segmentNames = (oldManifest["segments"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
        try #require(!segmentNames.isEmpty, "the migration race needs at least one actual segment")
        try #require(segmentNames.allSatisfy {
            FileManager.default.isReadableFile(atPath: V8.segmentsDirectory(manifestURL).appendingPathComponent($0).path)
        }, "all referenced fixture segments must be readable before migration starts")
        oldManifest["version"] = 9
        oldManifest.removeValue(forKey: "forwardedSenderRefreshPending")
        let oldData = try JSONSerialization.data(withJSONObject: oldManifest)
        try oldData.write(to: manifestURL, options: .atomic)
        let oldMeta = TranscriptCache.Meta(complete: true, activityMs: 10, version: 9, retained: false)
        try JSONEncoder().encode(oldMeta).write(to: manifestURL.appendingPathExtension("meta"), options: .atomic)

        let gate = MigrationWriteGate()
        let migrationRead = Task {
            await TranscriptCache.read(
                manifestURL, gatewayId: gateway, root: temp.url,
                legacyManifestMigrationWriteObserver: { phase in
                    switch phase {
                    case .beforeEnqueue: await gate.pauseBeforeEnqueue()
                    case .finished: await gate.markFinished()
                    }
                }, migrationWriter: writer, priority: .utility)
        }
        let restored = await migrationRead.value
        try #require(restored.outcome == .migrated(from: 9), "the readable v9 fixture must take the migration path")
        #expect(restored.snapshot?.items.first?.sender == nil, "the legacy cache begins without sender attribution")
        await gate.waitUntilPaused()

        var repairedRow = oldRow
        repairedRow.sender = MessageSender(kind: .agent, sessionKey: "agent:kiko:main", agentId: "kiko")
        var authoritative = TranscriptCache.Snapshot(items: [repairedRow], complete: true, activityMs: 10)
        authoritative.forwardedSenderRefreshCompleted = true
        let repaired = await writer.write(authoritative, to: manifestURL)
        #expect(repaired.modified != nil || repaired.unchanged,
                "the authoritative sender refresh must commit while the legacy write is paused")
        await writer.drain()

        await gate.release()
        await gate.waitUntilFinished()
        let reloaded = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: sessionKey, root: temp.url))
        #expect(reloaded.items.first?.sender?.agentId == "kiko",
                "a delayed migration write must not replace the authoritative sender attribution")
        #expect(!reloaded.forwardedSenderRefreshPending)
    }
}

private actor MigrationWriteGate {
    private var paused = false
    private var released = false
    private var finished = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func pauseBeforeEnqueue() async {
        self.paused = true
        self.pauseWaiter?.resume()
        self.pauseWaiter = nil
        guard !self.released else { return }
        await withCheckedContinuation { self.releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        guard !self.paused else { return }
        await withCheckedContinuation { self.pauseWaiter = $0 }
    }

    func release() {
        self.released = true
        self.releaseWaiter?.resume()
        self.releaseWaiter = nil
    }

    func markFinished() {
        self.finished = true
        self.finishWaiter?.resume()
        self.finishWaiter = nil
    }

    func waitUntilFinished() async {
        guard !self.finished else { return }
        await withCheckedContinuation { self.finishWaiter = $0 }
    }
}
