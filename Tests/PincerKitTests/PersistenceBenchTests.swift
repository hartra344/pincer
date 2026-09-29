import Foundation
import Testing
@testable import PincerKit

/// Measurements for the transcript cache and message index (#199); a no-op unless `PINCER_BENCH=1`.
/// Run through `scripts/bench-persistence.sh`, which sets `PINCER_BENCH_PHASE` (`disk`, `launch`,
/// `stream`), starts the mock Gateway and fixes the cache folder, so before and after numbers
/// come from the same harness.
@Suite("Persistence bench", .serialized, .enabled(if: Bench.enabled))
@MainActor
struct PersistenceBenchTests {
    @Test func bytesAndIndexPerSave() async throws {
        guard Bench.phase == "disk" else { return }
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let key = "agent:main:bench"
        var items = (0..<20000).map(Bench.item)
        await TranscriptCache.save(.init(items: items, complete: true, activityMs: 1), gatewayId: gateway,
                                   sessionKey: key, root: temp.url)
        let directory = try #require(TranscriptCache.directory(gatewayId: gateway, root: temp.url))
        var listing = Bench.listing(directory)
        Bench.report("disk.items", 20000.0)
        Bench.report("disk.fullSizeBytes", Bench.total(listing))

        items.append(Bench.item(20000))
        let appended = TranscriptCache.Snapshot(items: items, complete: true, activityMs: 2)
        let clock = ContinuousClock()
        let cpu = Bench.cpuSeconds()
        let wall = await clock.measure {
            await TranscriptCache.save(appended, gatewayId: gateway, sessionKey: key, root: temp.url)
        }
        Bench.report("disk.appendOne.saveWallMs", Bench.ms(wall))
        Bench.report("disk.appendOne.saveCpuMs", (Bench.cpuSeconds() - cpu) * 1000)
        var after = Bench.listing(directory)
        Bench.report("disk.appendOne.bytesWritten", Double(Bench.written(before: listing, after: after)))
        listing = after

        await TranscriptCache.save(appended, gatewayId: gateway, sessionKey: key, root: temp.url)
        after = Bench.listing(directory)
        Bench.report("disk.unchangedForcedSave.bytesWritten", Double(Bench.written(before: listing, after: after)))

        // Index alone: one more item appended to what's already indexed.
        items.append(Bench.item(20001))
        let next = TranscriptCache.Snapshot(items: items, complete: true, activityMs: 3)
        let index = MessageIndex.shared(gatewayId: gateway, root: temp.url)
        let indexCpu = Bench.cpuSeconds()
        let indexWall = await clock.measure {
            await index.index(sessionKey: key, snapshot: next, fileMtime: Date())
        }
        Bench.report("index.appendOne.wallMs", Bench.ms(indexWall))
        Bench.report("index.appendOne.cpuMs", (Bench.cpuSeconds() - indexCpu) * 1000)
        await MessageIndex.shutdown(root: temp.url)
    }

    /// After the change only: the production path, where the save hands the index `.tail`.
    @Test func indexTailPerSave() async throws {
        guard Bench.phase == "index-tail" else { return }
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let key = "agent:main:bench"
        var items = (0..<20000).map(Bench.item)
        await TranscriptCache.saveReturningStats(.init(items: items, complete: true, activityMs: 1), gatewayId: gateway,
                                                 sessionKey: key, root: temp.url)
        let index = MessageIndex.shared(gatewayId: gateway, root: temp.url)
        Bench.report("indexTail.firstSavePathFull", index.lastIndexStats.path == .full ? 1 : 0)

        items.append(Bench.item(20000))
        let cpu = Bench.cpuSeconds()
        let clock = ContinuousClock()
        var result = TranscriptCache.SaveResult()
        let wall = await clock.measure {
            result = await TranscriptCache.saveReturningStats(.init(items: items, complete: true, activityMs: 2),
                                                              gatewayId: gateway, sessionKey: key, root: temp.url)
        }
        let stats = index.lastIndexStats
        Bench.report("indexTail.saveWholeWallMs", Bench.ms(wall))
        Bench.report("indexTail.saveWholeCpuMs", (Bench.cpuSeconds() - cpu) * 1000)
        Bench.report("indexTail.saveBytesWritten", Double(result.bytesWritten))
        Bench.report("indexTail.pathIsTail", stats.path == .tail ? 1 : 0)
        Bench.report("indexTail.documentsBuilt", Double(stats.documentsBuilt))
        Bench.report("indexTail.rowsRead", Double(stats.rowsRead))
        Bench.report("indexTail.rowsWritten", Double(stats.rowsWritten))

        // The index call alone, with the token the second save produced as its base.
        guard case let .tail(_, _, token)? = result.change else {
            Bench.report("indexTail.changeWasTail", 0)
            return
        }
        items.append(Bench.item(20001))
        let next = TranscriptCache.Snapshot(items: items, complete: true, activityMs: 3)
        let indexCpu = Bench.cpuSeconds()
        let indexWall = await clock.measure {
            await index.index(sessionKey: key, snapshot: next, fileMtime: Date(),
                              change: .tail(unchangedPrefix: 20001, baseToken: token, token: "bench-next"))
        }
        Bench.report("indexTail.indexOnly.wallMs", Bench.ms(indexWall))
        Bench.report("indexTail.indexOnly.cpuMs", (Bench.cpuSeconds() - indexCpu) * 1000)
        Bench.report("indexTail.indexOnly.pathIsTail", index.lastIndexStats.path == .tail ? 1 : 0)
        await MessageIndex.shutdown(root: temp.url)
    }

    /// One app launch against the mock: connect, let the background prefetch run, quit.
    @Test func launch() async throws {
        guard Bench.phase == "launch" else { return }
        let gateway = Bench.gateway()
        let log = Bench.mockLog
        let base = Bench.historyReads(log)
        let baseTotal = Bench.allHistoryRequests(log)
        gateway.start()
        #expect(await Bench.wait(60) { gateway.state.isConnected && !gateway.sessions.isEmpty })
        // The prefetch starts after 2 s; it's done when the Gateway hasn't been asked for 5 s.
        var last = Bench.historyReads(log)
        var quiet = 0
        for _ in 0..<600 where quiet < 10 {
            try await Task.sleep(for: .milliseconds(500))
            let now = Bench.historyReads(log)
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
        await Bench.finish(gateway)
        Bench.report("launch.chatHistoryRequests.bigChat", Double(Bench.historyReads(log) - base))
        Bench.report("launch.chatHistoryRequests.total", Double(Bench.allHistoryRequests(log) - baseTotal))
    }

    /// The big chat open while replies stream: how often, and how much, the cache is rewritten.
    @Test func streaming() async throws {
        guard Bench.phase == "stream" else { return }
        let gateway = Bench.gateway()
        gateway.start()
        #expect(await Bench.wait(60) { gateway.state.isConnected && !gateway.sessions.isEmpty })
        let chat = gateway.chat(for: Bench.bigKey)
        await chat.load()
        #expect(await Bench.wait(120) { chat.hasLoaded && !chat.hasMoreHistory })
        try await Task.sleep(for: .seconds(3))
        let directory = try #require(TranscriptCache.directory(gatewayId: gateway.id))
        var listing = Bench.listing(directory)
        var saves = 0
        var bytes = 0
        let seconds = Bench.streamSeconds
        let start = ContinuousClock.now
        let cpu = Bench.cpuSeconds()
        var lastSend = Date.distantPast
        while ContinuousClock.now - start < .seconds(seconds) {
            if !chat.isRunning, Date().timeIntervalSince(lastSend) > 1 {
                lastSend = Date()
                await chat.send("tool call then a long reply")
            }
            try await Task.sleep(for: .milliseconds(100))
            let now = Bench.listing(directory)
            if now != listing {
                let written = Bench.written(before: listing, after: now)
                if written > 0 { saves += 1; bytes += written }
                listing = now
            }
        }
        Bench.report("stream.seconds", Double(seconds))
        Bench.report("stream.saves", Double(saves))
        Bench.report("stream.savesPerMinute", Double(saves) * 60 / Double(seconds))
        Bench.report("stream.bytesWritten", Double(bytes))
        Bench.report("stream.processCpuSeconds", Bench.cpuSeconds() - cpu)
        await Bench.finish(gateway)
    }
}

enum Bench {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["PINCER_BENCH"] == "1"
    static let phase = env["PINCER_BENCH_PHASE"] ?? ""
    static let bigKey = "agent:main:dashboard:trip"
    static let streamSeconds = Int(env["PINCER_BENCH_STREAM_SECONDS"] ?? "") ?? 60
    static let mockLog = env["PINCER_BENCH_MOCK_LOG"] ?? ""

    static func item(_ index: Int) -> ChatItem {
        let text = "Message \(index): " + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)
        var item = ChatItem(id: "bench-\(index)", role: index % 2 == 0 ? .user : .assistant, blocks: [.text(text)],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        item.transcriptId = item.id
        return item
    }

    /// Quits the store the way both old and new code allow: stop, then let queued cache writes land.
    @MainActor static func finish(_ gateway: GatewayStore) async {
        gateway.stop()
        await TranscriptCache.flush(gatewayId: gateway.id)
    }

    /// A store on the mock at `PINCER_BENCH_URL`, with a Gateway id that survives across launches.
    @MainActor static func gateway() -> GatewayStore {
        let id = UUID(uuidString: env["PINCER_BENCH_GATEWAY_ID"] ?? "") ?? UUID()
        let profile = GatewayProfile(id: id, name: "Bench", url: env["PINCER_BENCH_URL"] ?? "ws://127.0.0.1:18931",
                                     authMode: .none)
        return GatewayStore(profile: profile, defaults: ScratchDefaults().defaults, identity: Fixtures.identity())
    }

    @MainActor static func wait(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    static func historyReads(_ log: String) -> Int {
        lines(log).filter { $0.hasPrefix("BENCH_HISTORY") }.count
    }

    static func allHistoryRequests(_ log: String) -> Int {
        lines(log).filter { $0.hasSuffix(" chat.history") }.count
    }

    private static func lines(_ log: String) -> [Substring] {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    struct Entry: Equatable {
        var size: Int
        var modified: Date
        var inode: UInt64
    }

    /// Transcript files only: the message index is a database whose size isn't what a save writes.
    static func listing(_ directory: URL) -> [String: Entry] {
        var result: [String: Entry] = [:]
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in walker where !url.lastPathComponent.hasPrefix("search-index") {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            result[url.path(percentEncoded: false)] = Entry(
                size: (attributes[.size] as? Int) ?? 0,
                modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
                inode: (attributes[.systemFileNumber] as? UInt64) ?? 0)
        }
        return result
    }

    static func total(_ listing: [String: Entry]) -> Double {
        Double(listing.values.reduce(0) { $0 + $1.size })
    }

    /// Bytes of files that are new or rewritten (another inode, size or mtime) since `before`.
    static func written(before: [String: Entry], after: [String: Entry]) -> Int {
        after.reduce(0) { $0 + (before[$1.key] == $1.value ? 0 : $1.value.size) }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func report(_ name: String, _ value: Double) {
        print("BENCH \(name) = \(String(format: "%.1f", value))")
    }
}
