import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

enum Synthetic {
    static let syllables = ["ka", "lo", "mi", "ren", "to", "sha", "vel", "dor", "qui", "nex", "bra", "fu", "zel", "po", "tri", "gan"]
    static let words: [String] = (0..<4096).map { n in
        syllables[n & 15] + syllables[(n >> 4) & 15] + syllables[(n >> 8) & 15]
    }

    /// About 400 characters per message. Every message has "the" and "and"; every 100th has "lantern glow",
    /// every 150th "harbor light"; message 1000 + chat has "zephyr<chat>".
    static func items(chat: Int, count: Int) -> [ChatItem] {
        var state = UInt64(chat + 1) &* 0x9E37_79B9_7F4A_7C15
        let start = 1_700_000_000.0 + Double(chat) * 7
        return (0..<count).map { i in
            var text = "the"
            var n = 0
            while text.utf8.count < 390 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += " " + words[Int(state >> 52)]
                n += 1
                if n == 20 { text += " and" }
            }
            if i % 100 == 7 { text += " lantern glow" }
            if i % 150 == 11 { text += " harbor light" }
            if i == 1000 + chat { text += " zephyr\(chat)" }
            text += "."
            var item = ChatItem(id: "c\(chat)-\(i)", role: i.isMultiple(of: 2) ? .user : .assistant, blocks: [.text(text)],
                                timestamp: Date(timeIntervalSince1970: start + Double(i) * 60))
            item.transcriptId = item.id
            return item
        }
    }
}

/// Resident size and physical footprint, bytes.
func memoryUsage() -> (resident: UInt64, footprint: UInt64) {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? (info.ri_resident_size, info.ri_phys_footprint) : (0, 0)
}

/// Samples memory on a background thread until stopped; keeps the peak.
final class MemorySampler: Sendable {
    private let state = Mutex<(peakResident: UInt64, peakFootprint: UInt64, running: Bool)>((0, 0, true))

    init() {
        let thread = Thread { [self] in
            while self.state.withLock({ $0.running }) {
                let usage = memoryUsage()
                self.state.withLock { $0.peakResident = max($0.peakResident, usage.resident); $0.peakFootprint = max($0.peakFootprint, usage.footprint) }
                usleep(10000)
            }
        }
        thread.start()
    }

    func stop() -> (resident: UInt64, footprint: UInt64) {
        let usage = memoryUsage()
        return self.state.withLock {
            $0.running = false
            return (max($0.peakResident, usage.resident), max($0.peakFootprint, usage.footprint))
        }
    }
}

func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

func directorySize(_ url: URL, _ include: (String) -> Bool) -> Int64 {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
    return names.filter(include).reduce(0) { total, name in
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.appending(path: name).path(percentEncoded: false))
        return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

/// Always on: 2 chats × 5k messages build in ≤ 3 s; a selective query ≤ 100 ms (budgets relaxed
/// to clearly-broken limits with --skip-perf-budgets).
@MainActor
func checkMessageIndexPerfSmoke() async {
    let gatewayId = UUID()
    let chats = (0..<2).map { Synthetic.items(chat: $0, count: 5000) }
    let clock = ContinuousClock()
    let build = await clock.measure {
        for (chat, items) in chats.enumerated() {
            await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "perf\(chat)")
        }
    }
    checkBudget(build, .seconds(3), hardLimit: .seconds(10), "perf smoke: 2 × 5k messages saved and indexed in \(build.formatted(.units(allowed: [.milliseconds])))")
    let keys: Set<String> = ["perf0", "perf1"]
    var worst = Duration.zero
    var groups: [MessageSearch.ChatGroup] = []
    for _ in 0..<5 {
        let elapsed = await clock.measure { groups = await indexResults(gatewayId, "lantern glow", keys: keys) }
        worst = max(worst, elapsed)
    }
    check(groups.count == 2 && groups.allSatisfy { $0.hits.count == 3 && $0.hasMore } && groups.first?.sessionKey == "perf1",
          "perf smoke: selective query results")
    checkBudget(worst, .milliseconds(100), hardLimit: .seconds(1), "perf smoke: selective query, slowest of 5: \(worst.formatted(.units(allowed: [.milliseconds])))")
    // Cancelling one search mustn't stop another that wasn't cancelled (e.g. a second window's).
    let index = MessageIndex.shared(gatewayId: gatewayId)
    var bystanderOK = 0
    for delay in [0, 250, 500, 1000, 2000] {
        let bystander = Task { @MainActor in try await index.search("the", candidateLimit: 1_000_000) }
        if delay == 0 { await Task.yield() } else { try? await Task.sleep(for: .microseconds(delay)) }
        let cancelled = Task { @MainActor in
            try await withTaskCancellationHandler { try await index.search("lantern") } onCancel: { index.interrupt() }
        }
        cancelled.cancel()
        _ = await cancelled.result
        if case let .success(hits) = await bystander.result, hits.count == 10_000 { bystanderOK += 1 }
    }
    check(bystanderOK == 5, "cancelling one search doesn't interrupt another, larger index (\(bystanderOK)/5 survived)")
    var appended = chats[0]
    appended.append(messageItem("new", .user, "freshly appended pelican", at: 1_800_000_000))
    let incremental = await clock.measure {
        await TranscriptCache.save(TranscriptCache.Snapshot(items: appended, complete: true), gatewayId: gatewayId, sessionKey: "perf0")
    }
    await checkAsync({ await indexHits(gatewayId, "pelican").count == 1 }, "perf smoke: appended message indexed")
    checkBudget(incremental, .milliseconds(1000), hardLimit: .seconds(5),
                "perf smoke: append to a 5k chat saved and indexed in \(incremental.formatted(.units(allowed: [.milliseconds])))")
    TranscriptCache.removeAll(gatewayId: gatewayId)
}

/// `--perf`: 20 chats × 20k messages against the §4 targets.
@MainActor
func runMessageIndexPerf() async {
    await withScratchCache { _ in
        let gatewayId = UUID()
        let chatCount = 20
        let perChat = 20_000
        let keys = (0..<chatCount).map { "perf:\($0)" }
        let clock = ContinuousClock()
        let generation = clock.measure {
            for chat in 0..<chatCount {
                _ = writeCacheFile(TranscriptCache.Snapshot(items: Synthetic.items(chat: chat, count: perChat), complete: true),
                                   gatewayId: gatewayId, sessionKey: keys[chat])
            }
        }
        print("  · wrote \(chatCount) × \(perChat) synthetic transcripts in \(generation.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
        let directory = TranscriptCache.directory(gatewayId: gatewayId)!
        let jsonSize = directorySize(directory) { $0.hasSuffix(".json") }

        let index = MessageIndex.shared(gatewayId: gatewayId)
        let baseline = memoryUsage()
        let sampler = MemorySampler()
        let log = StatusLog()
        let start = clock.now
        await index.reconcile(sessionKeys: keys) { await log.add($0) }
        let total = clock.now - start
        let peak = sampler.stop()
        let stamps = await log.times
        let perChatTimes = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let slowest = perChatTimes.max() ?? .zero
        await checkAsync({ await allTrue(log.statuses.count == chatCount + 1, (log.statuses).last == .ready) }, "perf: reconcile built every chat")
        let buildGrowth = Int64(peak.footprint) - Int64(baseline.footprint)
        print("  · build: \(total.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))) total, slowest chat \(slowest.formatted(.units(allowed: [.milliseconds])))")
        print("  · build memory: footprint +\(mb(buildGrowth)) peak, resident +\(mb(Int64(peak.resident) - Int64(baseline.resident))) peak")
        check(total <= .seconds(20), "perf: full build ≤ 20 s")
        check(slowest <= .milliseconds(1500), "perf: ≤ 1.5 s per chat")
        check(buildGrowth <= 100 * 1_048_576, "perf: build peak ≤ 100 MB above baseline (footprint)")

        let indexSize = directorySize(directory) { $0.hasPrefix("search-index.sqlite") }
        let walSize = directorySize(directory) { $0 == "search-index.sqlite-wal" }
        let pages = sqliteInts(MessageIndex.url(gatewayId: gatewayId), "PRAGMA page_count")
        let freePages = sqliteInts(MessageIndex.url(gatewayId: gatewayId), "PRAGMA freelist_count")
        print("  · index files: main \(mb(indexSize - walSize)), WAL \(mb(walSize)); pages \(pages.first ?? 0), free \(freePages.first ?? 0)")
        print("  · index \(mb(indexSize)) vs transcript JSON \(mb(jsonSize)) (\(String(format: "%.0f", Double(indexSize) / Double(jsonSize) * 100))%)")
        check(indexSize <= jsonSize, "perf: index size ≤ transcript JSON size")

        var appended = Synthetic.items(chat: 0, count: perChat)
        appended.append(messageItem("perf-new", .user, "incremental ibex arrives", at: 1_900_000_000))
        await TranscriptCache.save(TranscriptCache.Snapshot(items: appended, complete: true), gatewayId: gatewayId, sessionKey: keys[0])
        appended.append(messageItem("perf-new2", .user, "second ibex", at: 1_900_000_100))
        let snapshot = TranscriptCache.Snapshot(items: appended, complete: true)
        let incremental = await clock.measure { await index.index(sessionKey: keys[0], snapshot: snapshot, fileMtime: Date()) }
        let unchanged = await clock.measure { await index.index(sessionKey: keys[0], snapshot: snapshot, fileMtime: Date()) }
        print("  · incremental update of a 20k chat: \(incremental.formatted(.units(allowed: [.milliseconds]))), unchanged: \(unchanged.formatted(.units(allowed: [.milliseconds])))")
        await checkAsync({ await allTrue(indexHits(gatewayId, "ibex").count == 2, incremental <= .milliseconds(300)) }, "perf: incremental update ≤ 300 ms")

        let allowed = Set(keys)
        let queries: [(kind: String, text: String)] =
            (0..<8).map { ("rare", "zephyr\($0 * 2)") }
            + [("selective", "lantern"), ("selective", "lantern glow"), ("selective", "harbor light"), ("selective", "harbor")]
            + [("common", "the"), ("common", "and"), ("common", "The"), ("common", "AND")]
            + [("prefix", "ka"), ("prefix", "lo"), ("prefix", "mi"), ("prefix", "to")]
        let searchBaseline = memoryUsage()
        let searchSampler = MemorySampler()
        var byKind: [String: [Duration]] = [:]
        var all: [Duration] = []
        var ok = true
        for query in queries {
            var groups: [MessageSearch.ChatGroup] = []
            let elapsed = await clock.measure {
                groups = MessageSearch.collect((try? await index.search(query.text)) ?? [], query: query.text, allowed: allowed)
            }
            byKind[query.kind, default: []].append(elapsed)
            all.append(elapsed)
            if query.kind == "rare", groups.count != 1 || groups[0].hits.count != 1 { ok = false; print("    \(query.text): \(groups.count) chats") }
            if query.kind == "selective", groups.count != 20 { ok = false; print("    \(query.text): \(groups.count) chats") }
        }
        let searchPeak = searchSampler.stop()
        func p95(_ values: [Duration]) -> Duration {
            let sorted = values.sorted()
            return sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        }
        func ms(_ duration: Duration) -> String { duration.formatted(.units(allowed: [.milliseconds])) }
        for kind in ["rare", "selective", "common", "prefix"] {
            let values = byKind[kind] ?? []
            print("  · \(kind): p95 \(ms(p95(values))), max \(ms(values.max() ?? .zero)) over \(values.count)")
        }
        print("  · all 20 queries: p95 \(ms(p95(all)))")
        let searchGrowth = Int64(searchPeak.footprint) - Int64(searchBaseline.footprint)
        print("  · search memory: footprint +\(mb(searchGrowth)) peak")
        check(ok, "perf: queries find what was planted")
        check(p95((byKind["rare"] ?? []) + (byKind["selective"] ?? [])) <= .milliseconds(100), "perf: selective query p95 ≤ 100 ms")
        check((byKind["common"] ?? []).max()! <= .milliseconds(500) && (byKind["prefix"] ?? []).max()! <= .milliseconds(500),
              "perf: common and 2-letter queries ≤ 500 ms")
        check(searchGrowth <= 30 * 1_048_576, "perf: searching grows memory ≤ 30 MB")

        // A huge search is cancellable.
        let uncancelled = await clock.measure { _ = try? await index.search("the", candidateLimit: 10_000_000) }
        let big = Task { @MainActor in
            try await withTaskCancellationHandler {
                try await index.search("the", candidateLimit: 10_000_000)
            } onCancel: { index.interrupt() }
        }
        let cancelStart = clock.now
        try? await Task.sleep(for: .milliseconds(20))
        big.cancel()
        let bigOutcome = await big.result
        let cancelled = clock.now - cancelStart
        var wasCancelled = false
        if case let .failure(error) = bigOutcome { wasCancelled = error is CancellationError }
        print("  · unlimited \"the\": \(ms(uncancelled)); cancelled after 20 ms: stopped at \(ms(cancelled)) (cancelled: \(wasCancelled))")
        check(cancelled <= .milliseconds(200) || !wasCancelled, "perf: a huge search stops soon after cancelling")
        TranscriptCache.removeAll(gatewayId: gatewayId)
    }
}
