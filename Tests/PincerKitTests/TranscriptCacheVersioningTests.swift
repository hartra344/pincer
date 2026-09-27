import Foundation
import Testing
@testable import PincerKit

/// Versioned transcript cache files: migration, discarding and quarantining corrupt files.
@Suite("Transcript cache versioning")
struct TranscriptCacheVersioningTests {
    let gateway = UUID()
    let key = "agent:main:main"

    typealias Cache = TranscriptCache
    static let current = TranscriptCache.Snapshot.currentVersion

    func snapshotData(version: Int = current, ids: [String] = ["a", "b"], complete: Bool = true) throws -> Data {
        try JSONEncoder().encode(Cache.Snapshot(version: version, items: ids.map { item($0) }, complete: complete, activityMs: 42))
    }

    /// Writes raw bytes as the chat's transcript, plus a valid `.meta` sidecar.
    @discardableResult
    func writeRaw(_ data: Data, root: URL, key: String? = nil) throws -> URL {
        let file = try #require(Cache.file(gatewayId: self.gateway, sessionKey: key ?? self.key, root: root))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try JSONEncoder().encode(Cache.Meta(complete: true, activityMs: 42, version: Self.current))
            .write(to: file.appendingPathExtension("meta"))
        return file
    }

    func quarantined(_ temp: TempDir) throws -> Set<String> {
        temp.contents(of: try #require(Cache.quarantineDirectory(gatewayId: self.gateway, root: temp.url)))
    }

    func isCorrupt(_ outcome: Cache.LoadOutcome) -> Bool {
        if case .corrupt = outcome { true } else { false }
    }

    // MARK: Pure decode

    @Test func decodeCurrentVersion() throws {
        let (snapshot, outcome) = Cache.decode(try self.snapshotData())
        #expect(outcome == .loaded && !outcome.discarded)
        #expect(snapshot?.items.map(\.id) == ["a", "b"] && snapshot?.complete == true && snapshot?.activityMs == 42)
        #expect(snapshot?.version == Self.current)
    }

    @Test func decodeFutureVersion() throws {
        let (snapshot, outcome) = Cache.decode(try self.snapshotData(version: Self.current + 1))
        #expect(snapshot == nil && outcome == .future(version: Self.current + 1) && outcome.discarded)
    }

    @Test func decodeUnmigratableVersion() throws {
        let old = Cache.oldestMigratableVersion - 1
        let (snapshot, outcome) = Cache.decode(try self.snapshotData(version: old))
        #expect(snapshot == nil && outcome == .outdated(version: old) && outcome.discarded)
        #expect(Cache.decode(Data(#"{"version":0,"items":[],"complete":true}"#.utf8)).outcome == .outdated(version: 0))
    }

    @Test func oldestMigratableVersionIsCoveredByTheChain() {
        #expect(Cache.oldestMigratableVersion <= Self.current)
        for version in Cache.oldestMigratableVersion..<Self.current {
            #expect(Cache.migrations[version] != nil, "no migration from v\(version)")
        }
    }

    @Test(arguments: [
        ("empty", Data()),
        ("whitespace", Data("  \n".utf8)),
        ("garbage", Data("not json at all \u{00}\u{ff}".utf8)),
        ("binary", Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01])),
        ("array", Data("[1,2,3]".utf8)),
        ("no version", Data(#"{"items":[],"complete":true}"#.utf8)),
        ("string version", Data(#"{"version":"5","items":[],"complete":true}"#.utf8)),
        ("wrong shape", Data(#"{"version":5,"items":{"a":1},"complete":true}"#.utf8)),
        ("missing items", Data(#"{"version":5,"complete":true}"#.utf8)),
    ])
    func decodeCorrupt(_ label: String, _ data: Data) {
        let (snapshot, outcome) = Cache.decode(data)
        #expect(snapshot == nil && self.isCorrupt(outcome) && outcome.discarded, "\(label): \(outcome)")
    }

    @Test func decodeTruncatedAtEveryHalf() throws {
        let data = try self.snapshotData(ids: (0..<20).map { "m\($0)" })
        for cut in [1, data.count / 4, data.count / 2, data.count - 1] {
            let (snapshot, outcome) = Cache.decode(data.prefix(cut))
            #expect(snapshot == nil && self.isCorrupt(outcome), "cut at \(cut) of \(data.count): \(outcome)")
        }
    }

    // MARK: Migration machinery (injected chain)

    @Test func migrationChainRunsEveryStep() throws {
        let v = Self.current
        // A v(current-2) file whose items live under "messages"; two steps bring it to current.
        var old = try #require(try JSONSerialization.jsonObject(with: try self.snapshotData()) as? [String: Any])
        old["messages"] = old.removeValue(forKey: "items")
        old["version"] = v - 2
        let data = try JSONSerialization.data(withJSONObject: old)
        let steps = StepLog()
        let chain: [Int: Cache.Migration] = [
            v - 2: { object in
                steps.append(v - 2)
                object["items"] = object.removeValue(forKey: "messages")
            },
            v - 1: { object in
                steps.append(v - 1)
                object["complete"] = false
            },
        ]
        let (snapshot, outcome) = Cache.decode(data, migrations: chain, oldestMigratableVersion: v - 2)
        #expect(outcome == .migrated(from: v - 2) && !outcome.discarded)
        #expect(steps.values == [v - 2, v - 1])
        #expect(snapshot?.items.map(\.id) == ["a", "b"] && snapshot?.complete == false)
        #expect(snapshot?.version == v)

        // Entering midway only runs the remaining steps.
        steps.reset()
        let midway = Cache.decode(try self.snapshotData(version: v - 1), migrations: chain, oldestMigratableVersion: v - 2)
        #expect(midway.outcome == .migrated(from: v - 1) && steps.values == [v - 1] && midway.snapshot?.complete == false)
    }

    @Test func migrationGapOrFailureIsDiscarded() throws {
        let v = Self.current
        // Chain missing a step.
        let gap = Cache.decode(try self.snapshotData(version: v - 2), migrations: [v - 1: { _ in }], oldestMigratableVersion: v - 2)
        #expect(gap.snapshot == nil && gap.outcome == .outdated(version: v - 2))
        // A step that throws.
        struct Nope: Error {}
        let failing = Cache.decode(try self.snapshotData(version: v - 1), migrations: [v - 1: { _ in throw Nope() }],
                                   oldestMigratableVersion: v - 1)
        #expect(failing.snapshot == nil && failing.outcome == .outdated(version: v - 1))
        // A step that leaves an undecodable shape.
        let broken = Cache.decode(try self.snapshotData(version: v - 1), migrations: [v - 1: { $0["items"] = 7 }],
                                  oldestMigratableVersion: v - 1)
        #expect(broken.snapshot == nil && broken.outcome.discarded)
        // Below the oldest migratable version, even with a chain.
        let tooOld = Cache.decode(try self.snapshotData(version: v - 1), migrations: [v - 1: { _ in }], oldestMigratableVersion: v)
        #expect(tooOld.snapshot == nil && tooOld.outcome == .outdated(version: v - 1))
    }

    // MARK: On disk

    @Test func missingFile() async {
        let temp = TempDir()
        defer { temp.remove() }
        let (snapshot, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && outcome == .missing && !outcome.discarded)
        #expect(await Cache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func currentVersionRoundTrip() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let snapshot = Cache.Snapshot(items: [item("a"), item("b")], complete: false, activityMs: 7)
        await Cache.save(snapshot, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let (loaded, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .loaded)
        #expect(loaded?.items == snapshot.items && loaded?.complete == false && loaded?.activityMs == 7)
        // Loading twice is stable and leaves the files alone.
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome == .loaded)
        let file = try #require(Cache.file(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(temp.exists(file) && temp.exists(file.appendingPathExtension("meta")))
    }

    @Test func outdatedFileIsDeleted() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let old = Cache.oldestMigratableVersion - 1
        let file = try self.writeRaw(try self.snapshotData(version: old), root: temp.url)
        let (snapshot, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && outcome == .outdated(version: old))
        #expect(!temp.exists(file) && !temp.exists(file.appendingPathExtension("meta")))
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome == .missing)
        // Not damaged, so not quarantined.
        #expect(try self.quarantined(temp).isEmpty)
    }

    @Test func futureFileIsDiscarded() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let file = try self.writeRaw(try self.snapshotData(version: Self.current + 3), root: temp.url)
        let (snapshot, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && outcome == .future(version: Self.current + 3))
        #expect(!temp.exists(file) && !temp.exists(file.appendingPathExtension("meta")))
        #expect(try self.quarantined(temp).isEmpty)
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome == .missing)
    }

    @Test(arguments: ["garbage", "empty", "truncated"])
    func corruptFileIsQuarantined(_ kind: String) async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let data: Data = switch kind {
        case "empty": Data()
        case "truncated": try self.snapshotData(ids: (0..<10).map { "m\($0)" }).prefix(80)
        default: Data("🦞 definitely not json".utf8)
        }
        let file = try self.writeRaw(data, root: temp.url)
        let (snapshot, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(snapshot == nil && self.isCorrupt(outcome), "\(outcome)")
        #expect(!temp.exists(file), "corrupt file left in place")
        #expect(!temp.exists(file.appendingPathExtension("meta")), ".meta sidecar left behind")
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)

        let quarantine = try #require(Cache.quarantineDirectory(gatewayId: self.gateway, root: temp.url))
        #expect(quarantine.deletingLastPathComponent() == file.deletingLastPathComponent())
        let names = try self.quarantined(temp)
        #expect(names.count == 1)
        let digest = file.deletingPathExtension().lastPathComponent
        #expect(names.allSatisfy { $0.hasPrefix(digest) })
        // The bytes are kept as-is for inspection.
        let kept = try #require(names.first)
        #expect(try Data(contentsOf: quarantine.appending(path: kept)) == data)
        // Nothing to re-quarantine next time.
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome == .missing)
        #expect(try self.quarantined(temp).count == 1)
    }

    @Test func saveAndLoadWorkAfterCorruption() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        try self.writeRaw(Data("{\"version\":5,\"items\":[".utf8), root: temp.url)
        #expect(self.isCorrupt(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome))
        let fresh = Cache.Snapshot(items: [item("fresh")], complete: true, activityMs: 99)
        await Cache.save(fresh, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let (loaded, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .loaded && loaded?.items.map(\.id) == ["fresh"])
        let meta = try #require(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(meta.complete && meta.activityMs == 99)
    }

    @Test func quarantineIsBounded() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let total = Cache.maxQuarantined + 4
        for index in 0..<total {
            try self.writeRaw(Data("junk \(index)".utf8), root: temp.url, key: "agent:main:chat\(index)")
            let outcome = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: "agent:main:chat\(index)", root: temp.url).outcome
            #expect(self.isCorrupt(outcome))
            // Distinct timestamps in the names.
            try await Task.sleep(for: .milliseconds(3))
        }
        let quarantine = try #require(Cache.quarantineDirectory(gatewayId: self.gateway, root: temp.url))
        let names = try self.quarantined(temp)
        #expect(names.count == Cache.maxQuarantined, "\(names.count) quarantined")
        // The newest are kept.
        let kept = Set(names.compactMap { try? String(decoding: Data(contentsOf: quarantine.appending(path: $0)), as: UTF8.self) })
        #expect(kept == Set((total - Cache.maxQuarantined..<total).map { "junk \($0)" }))
        // The same chat corrupted repeatedly is bounded too.
        for index in 0..<total {
            try self.writeRaw(Data("again \(index)".utf8), root: temp.url)
            _ = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        }
        #expect(try self.quarantined(temp).count <= Cache.maxQuarantined)
    }

    @Test func quarantineIsPerGatewayAndNotACacheFile() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        try self.writeRaw(Data("junk".utf8), root: temp.url)
        _ = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let other = UUID()
        let mine = try #require(Cache.quarantineDirectory(gatewayId: self.gateway, root: temp.url))
        let theirs = try #require(Cache.quarantineDirectory(gatewayId: other, root: temp.url))
        #expect(mine != theirs)
        #expect(Cache.quarantineDirectory(gatewayId: self.gateway, root: nil) == nil)
        // A healthy chat on the same Gateway is unaffected.
        await Cache.save(Cache.Snapshot(items: [item("ok")], complete: true), gatewayId: self.gateway, sessionKey: "agent:main:ok", root: temp.url)
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: "agent:main:ok", root: temp.url).outcome == .loaded)
        // Removing the Gateway's cache takes the quarantine with it.
        Cache.removeAll(gatewayId: self.gateway, root: temp.url)
        #expect(!temp.exists(mine))
    }

    @Test func migratedFileIsRewrittenAtCurrentVersion() async throws {
        // No shipped migration yet; when one exists, a file one step behind must load as migrated.
        let from = Self.current - 1
        guard from >= Cache.oldestMigratableVersion, Cache.migrations[from] != nil else { return }
        let temp = TempDir()
        defer { temp.remove() }
        let file = try self.writeRaw(try self.snapshotData(version: from), root: temp.url)
        let (snapshot, outcome) = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(outcome == .migrated(from: from) && snapshot != nil)
        let rewritten = Cache.decode(try Data(contentsOf: file))
        #expect(rewritten.outcome == .loaded)
    }

    @Test func metaWithoutTranscriptIsIgnored() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let file = try self.writeRaw(try self.snapshotData(), root: temp.url)
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)?.activityMs == 42)
        try FileManager.default.removeItem(at: file)
        #expect(temp.exists(file.appendingPathExtension("meta")))
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        // An empty transcript doesn't count either.
        try Data().write(to: file)
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func metaForAnotherVersionIsIgnored() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let file = try self.writeRaw(try self.snapshotData(), root: temp.url)
        let sidecar = file.appendingPathExtension("meta")
        // Written before sidecars recorded a version.
        try Data(#"{"complete":true,"activityMs":42}"#.utf8).write(to: sidecar)
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        try JSONEncoder().encode(Cache.Meta(complete: true, activityMs: 42, version: Self.current - 1)).write(to: sidecar)
        #expect(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        // Saving writes a sidecar for the current version.
        await Cache.save(Cache.Snapshot(items: [item("a")], complete: false, activityMs: 8), gatewayId: self.gateway,
                         sessionKey: self.key, root: temp.url)
        let meta = try #require(await Cache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(meta.version == Self.current && meta.activityMs == 8 && !meta.complete)
    }

    @Test func legacyLoadWrapsOutcome() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        try self.writeRaw(Data("junk".utf8), root: temp.url)
        #expect(await Cache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(try self.quarantined(temp).count == 1)
    }

    // MARK: Clear cache

    @Test func removeEverythingAndDiskUsage() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        #expect(await Cache.diskUsage(root: temp.url) == 0)
        let other = UUID()
        let big = Cache.Snapshot(items: (0..<50).map { item("m\($0)") }, complete: true)
        await Cache.save(big, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        await Cache.save(big, gatewayId: other, sessionKey: self.key, root: temp.url)
        try self.writeRaw(Data("junk".utf8), root: temp.url, key: "agent:main:bad")
        _ = await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: "agent:main:bad", root: temp.url)
        let usage = await Cache.diskUsage(root: temp.url)
        let one = try JSONEncoder().encode(big).count
        #expect(usage >= Int64(2 * one), "usage \(usage) < 2 × \(one)")
        #expect(await Cache.diskUsage(root: nil) == 0)
        // Cache off: clearing is a no-op.
        Cache.removeEverything(root: nil)
        #expect(await Cache.diskUsage(root: temp.url) == usage)

        Cache.removeEverything(root: temp.url)
        #expect(await Cache.diskUsage(root: temp.url) == 0)
        #expect(await Cache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(await Cache.load(gatewayId: other, sessionKey: self.key, root: temp.url) == nil)
        // Still usable afterwards.
        await Cache.save(big, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(await Cache.loadWithOutcome(gatewayId: self.gateway, sessionKey: self.key, root: temp.url).outcome == .loaded)
    }
}

/// Records which migration steps ran (migrations are `@Sendable`).
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Int] = []
    var values: [Int] { self.lock.withLock { self.steps } }
    func append(_ step: Int) { self.lock.withLock { self.steps.append(step) } }
    func reset() { self.lock.withLock { self.steps.removeAll() } }
}
