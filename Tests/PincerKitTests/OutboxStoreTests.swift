import Foundation
import Testing
@testable import PincerKit

/// Outbox persistence (#46): one versioned file per Gateway, corrupt and newer files set aside.
@Suite("Outbox persistence")
struct OutboxStoreTests {
    let gateway = UUID()
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    func sample() -> Outbox {
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "k1", sessionKey: "agent:main:main", agentId: "main", text: "first", createdAt: self.created))
        box.enqueue(OutboxEntry(
            id: "k2", sessionKey: "agent:main:main", text: "second", replyToId: "m-9",
            replyPreview: ReplyPreview(text: "earlier", senderLabel: "Claw"), createdAt: self.created.addingTimeInterval(1),
            state: .failed(OutboxFailure(message: "invalid chat.send params", retryable: false)), attempts: 1))
        box.enqueue(OutboxEntry(id: "k3", sessionKey: "agent:research:main", text: "other", createdAt: self.created, state: .sending, attempts: 2))
        return box
    }

    func file(_ temp: TempDir, _ gateway: UUID? = nil) throws -> URL {
        try #require(OutboxStore.file(gatewayId: gateway ?? self.gateway, root: temp.url))
    }

    @Test func roundTripsInOrder() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        let (loaded, outcome) = await OutboxStore.load(gatewayId: self.gateway, root: temp.url)
        #expect(outcome == .loaded)
        #expect(loaded == self.sample())
        #expect(loaded?.entries.map(\.id) == ["k1", "k2", "k3"])
    }

    @Test func relaunchRecoversInterruptedSends() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        var loaded = try #require(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox)
        loaded.recoverAfterLaunch()
        #expect(loaded.entry(id: "k3")?.state == .queued, "killed mid-send → queued, same key")
        #expect(loaded.entry(id: "k2")?.isFailed == true)
        #expect(loaded.nextToSend(sessionKey: "agent:research:main")?.id == "k3")
        #expect(loaded.nextToSend(sessionKey: "agent:main:main")?.id == "k1")
        loaded.markSending(id: "k1")
        loaded.markSent(id: "k1")
        #expect(loaded.nextToSend(sessionKey: "agent:main:main") == nil, "failed k2 still blocks its session")
    }

    @Test func attachmentEntriesArentPersisted() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var box = self.sample()
        box.enqueue(OutboxEntry(id: "pic", sessionKey: "agent:main:main", text: "photo", createdAt: self.created, hasAttachments: true))
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        let loaded = await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox
        #expect(loaded?.entries.map(\.id) == ["k1", "k2", "k3"])
    }

    @Test func emptyOutboxRemovesTheFile() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        #expect(temp.exists(try self.file(temp)))
        await OutboxStore.save(Outbox(), gatewayId: self.gateway, root: temp.url)
        #expect(!temp.exists(try self.file(temp)))
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outcome == .missing)
    }

    @Test func laterSavesWin() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var box = self.sample()
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        box.markSent(id: "k1")
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox?.entries.map(\.id) == ["k2", "k3"])
    }

    @Test func gatewaysAreIsolated() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let other = UUID()
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: other, root: temp.url).outcome == .missing)
        OutboxStore.remove(gatewayId: other, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outcome == .loaded)
        OutboxStore.remove(gatewayId: self.gateway, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outcome == .missing)
    }

    @Test func disabledRootIsANoOp() async {
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: nil)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: nil).outcome == .missing)
    }

    @Test func corruptFileIsSetAside() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let url = try self.file(temp)
        try Data("{ not json".utf8).write(to: url)
        let (loaded, outcome) = await OutboxStore.load(gatewayId: self.gateway, root: temp.url)
        #expect(loaded == nil)
        if case .corrupt = outcome {} else { Issue.record("expected corrupt, got \(outcome)") }
        #expect(!temp.exists(url))
        #expect(temp.contents(of: temp.url).contains("\(self.gateway.uuidString).corrupt.json"))
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outcome == .missing)
        // A fresh save starts over without touching the quarantined copy.
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outcome == .loaded)
        #expect(temp.contents(of: temp.url).contains("\(self.gateway.uuidString).corrupt.json"))
    }

    @Test(arguments: [
        ("empty", ""),
        ("array", "[1,2]"),
        ("no version", #"{"outbox":{"entries":[]}}"#),
        ("string version", #"{"version":"1","outbox":{"entries":[]}}"#),
        ("bool version", #"{"version":true,"outbox":{"entries":[]}}"#),
        ("missing outbox", #"{"version":1}"#),
        ("bad entry", #"{"version":1,"outbox":{"entries":[{"id":"k"}]}}"#),
        ("bad state", #"{"version":1,"outbox":{"entries":[{"id":"k","sessionKey":"s","text":"t","createdAt":"2027-01-15T08:00:00Z","state":{"exploded":{}}}]}}"#),
    ])
    func decodeCorrupt(_ label: String, _ json: String) {
        let (outbox, outcome) = OutboxStore.decode(Data(json.utf8))
        #expect(outbox == nil, "\(label)")
        if case .corrupt = outcome {} else { Issue.record("\(label): \(outcome)") }
    }

    @Test func futureVersionIsSetAsideAndKept() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let url = try self.file(temp)
        let future = OutboxStore.currentVersion + 1
        let body = #"{"version":\#(future),"outbox":{"entries":[]},"newField":true}"#
        try Data(body.utf8).write(to: url)
        let (loaded, outcome) = await OutboxStore.load(gatewayId: self.gateway, root: temp.url)
        #expect(loaded == nil && outcome == .future(version: future))
        let aside = temp.url.appending(path: "\(self.gateway.uuidString).v\(future).json")
        #expect(temp.exists(aside) && !temp.exists(url))
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        #expect(try String(contentsOf: aside, encoding: .utf8) == body, "a newer app's file isn't overwritten")
    }

    /// Pins the v1 on-disk format: bump `OutboxStore.currentVersion` (and add a migration) if this breaks.
    @Test func decodesLiteralVersion1File() throws {
        let json = #"""
        {"outbox":{"entries":[
          {"attempts":1,"createdAt":"2027-01-15T08:00:00Z","hasAttachments":false,"id":"idem-1","sessionKey":"agent:main:main","state":{"failed":{"_0":{"message":"invalid chat.send params","retryable":false}}},"text":"hello"},
          {"createdAt":"2027-01-15T08:00:01Z","id":"idem-2","replyToId":"m-1","replyPreview":{"text":"earlier","senderLabel":"Claw"},"sessionKey":"agent:main:main","state":{"queued":{}},"text":"again"}
        ]},"version":1}
        """#
        let (outbox, outcome) = OutboxStore.decode(Data(json.utf8))
        #expect(outcome == .loaded)
        let entries = try #require(outbox?.entries)
        #expect(entries.map(\.id) == ["idem-1", "idem-2"])
        #expect(entries[0].state == .failed(OutboxFailure(message: "invalid chat.send params", retryable: false)))
        #expect(entries[1].state == .queued && entries[1].attempts == 0 && entries[1].replyPreview?.senderLabel == "Claw")
        #expect(entries[0].createdAt == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
    }

    @Test func writesTheCurrentVersion() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await OutboxStore.save(self.sample(), gatewayId: self.gateway, root: temp.url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: try self.file(temp))) as? [String: Any]
        #expect(json?["version"] as? Int == OutboxStore.currentVersion)
    }

    // #414: a store started right after another stopped must read the other's last write.

    @Test func loadWaitsForQueuedWrites() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "trigger", sessionKey: "agent:main:main", text: "t", createdAt: self.created, state: .sending, attempts: 1))
        OutboxStore.enqueueSave(box, gatewayId: self.gateway, root: temp.url)
        box.enqueue(OutboxEntry(id: "queued", sessionKey: "agent:main:main", text: "q", createdAt: self.created))
        OutboxStore.enqueueSave(box, gatewayId: self.gateway, root: temp.url)
        let loaded = await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox
        #expect(loaded?.entries.map(\.id) == ["trigger", "queued"], "not the first write alone")
    }

    @Test func saveNowWinsOverQueuedWrites() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var box = self.sample()
        OutboxStore.enqueueSave(box, gatewayId: self.gateway, root: temp.url)
        box.markSent(id: "k1")
        OutboxStore.saveNow(box, gatewayId: self.gateway, root: temp.url)
        await OutboxStore.flushWrites(gatewayId: self.gateway, root: temp.url)
        #expect(await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox?.entries.map(\.id) == ["k2", "k3"],
                "the older queued write never lands after the quit-time save")
    }

    @Test func removeWinsOverQueuedWrites() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        OutboxStore.enqueueSave(self.sample(), gatewayId: self.gateway, root: temp.url)
        OutboxStore.remove(gatewayId: self.gateway, root: temp.url)
        await OutboxStore.flushWrites(gatewayId: self.gateway, root: temp.url)
        #expect(!temp.exists(try self.file(temp)), "a removed Gateway's outbox isn't written back")
    }
}

/// #927: queued messages keep their exact location snapshot on disk only while they're queued,
/// in files that are protected at rest yet writable after the device locks.
@Suite("Outbox location at rest")
struct OutboxLocationAtRestTests {
    let gateway = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot() throws -> LocationContextSnapshot {
        try #require(LocationContextSnapshot.prepare(
            LocationFix(latitude: 47.606209, longitude: -122.332069, accuracyMeters: 12, timestamp: self.now), now: self.now))
    }

    @Test func snapshotLeavesDiskWhenSentOrDiscarded() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let url = try #require(OutboxStore.file(gatewayId: self.gateway, root: temp.url))
        func onDisk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "loc", sessionKey: "agent:main:main", text: "where", locationContext: try self.snapshot(), createdAt: self.now))
        box.enqueue(OutboxEntry(id: "other", sessionKey: "agent:main:main", text: "next", createdAt: self.now))
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        #expect(onDisk().contains("47.606209"))
        let restored = await OutboxStore.load(gatewayId: self.gateway, root: temp.url).outbox
        #expect(restored?.entry(id: "loc")?.locationContext == (try self.snapshot()), "precise location survives relaunch (#662)")

        box.markSending(id: "loc")
        box.markSent(id: "loc")
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        #expect(onDisk().contains("next"))
        #expect(!onDisk().contains("47.606209") && !onDisk().contains("122.332069"))

        box.enqueue(OutboxEntry(id: "loc2", sessionKey: "agent:main:main", text: "again", locationContext: try self.snapshot(), createdAt: self.now))
        box.markFailed(id: "loc2", kind: .rejected("bad"))
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        #expect(onDisk().contains("47.606209"))
        box.delete(id: "loc2")
        await OutboxStore.save(box, gatewayId: self.gateway, root: temp.url)
        #expect(!onDisk().contains("47.606209"), "deleting a failed message drops its snapshot")

        OutboxStore.remove(gatewayId: self.gateway, root: temp.url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func filesUseUntilFirstUnlockProtection() {
        #expect(OutboxStore.writeOptions.contains(.atomic))
        #expect(OutboxStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(!OutboxStore.writeOptions.contains(.completeFileProtection),
                "complete protection blocks rewriting the outbox after the device locks, stranding sent snapshots")
        #expect(OutboxStore.protection == .completeUntilFirstUserAuthentication)
    }
}
