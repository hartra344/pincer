import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
import Darwin
#endif

/// Hooks for #198's instrumentation; set both to nil to run this file on a build without it (the baseline was
/// measured that way). Everything else measures from the outside (thread CPU time, wall time, RSS).
@MainActor
enum PrefetchProbeShim {
    #if os(macOS)
    /// e.g. `{ "\($0.prefetchStats)" }`. nil on the baseline.
    static let stats: ((TranscriptList.Coordinator) -> String)? = { "\($0.prefetchStats)" }
    /// Off-main premeasure counters next to the main-thread TextKit counters.
    static let premeasure: ((TranscriptList.Coordinator) -> String)? = {
        let (mainLayouts, memoHits) = TranscriptText.measureStats
        return "\($0.premeasureStats); main TextKit layouts \(mainLayouts), memo hits \(memoHits), "
            + "worker layouts \(TranscriptPremeasurer.offMainLayouts.withLock { $0 })"
    }
    #endif
    /// e.g. `{ "\($0.decodedBytes) bytes, \($0.imageCount) images, peak downloads \($0.peakConcurrentDownloads)" }`.
    static let loaderStats: ((ArtifactImageLoader) -> String)? = {
        "decodedBytes \($0.decodedBytes / 1_048_576) MiB, imageCount \($0.imageCount), peak downloads \($0.peakConcurrentDownloads)"
    }
}

enum ProbeMeter {
    /// CPU seconds consumed by the calling thread (run the probe on the main thread).
    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    static func wall() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// phys_footprint in MiB, the number Activity Monitor and jetsam use.
    static func footprintMiB() -> Double {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }
}

#if os(macOS)
@MainActor
@Suite("TranscriptPrefetchProbe", .serialized)
struct TranscriptPrefetchProbe {
    static let key = "agent:probe:main"
    static let rowCount = 20_000
    static let idleCap = 20.0
    /// Tearing the table down mid-test crashes AppKit; the probe leaks its window instead.
    static var keepAlive: [(NSWindow, TranscriptList.Coordinator)] = []

    static func rows(count: Int) -> [TranscriptRow] {
        let variants = (0..<16).map { StreamingProbe.reply(bytes: 150 + $0 * 90) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(count)
        for n in 0..<count {
            let stamp = base.addingTimeInterval(Double(n))
            if n % 2 == 0 {
                var item = ChatItem(id: "u\(n)", role: .user, blocks: [.text("Question \(n): \(variants[n % 16].prefix(120 + (n % 7) * 60))")],
                                    timestamp: stamp)
                item.transcriptId = item.id
                rows.append(.entry(.user(item)))
            } else {
                var turn = AssistantTurn(id: "a\(n)", timestamp: stamp)
                turn.text = ["Reply \(n)\n\n" + variants[(n / 2) % 16]]
                turn.textTimestamps = [stamp]
                turn.textModelNames = [nil]
                turn.textIds = ["a\(n)"]
                rows.append(.entry(.assistant(turn)))
            }
        }
        return rows
    }

    /// Rows whose height is final, from the shared controller's heights.
    static func measuredRows(_ coordinator: TranscriptList.Coordinator) -> Int? {
        coordinator.controller.heights.values.filter(\.measured).count
    }

    struct Spin {
        var wall = 0.0
        var cpu = 0.0
        var reachedIdle = false
    }

    /// Lets the main queue run in 100 ms slices (a blocking run-loop spin can't drain it from inside a main-actor
    /// job) until four in a row use under 1 ms of main-thread CPU (prefetch is idle), or `cap` seconds pass.
    static func spinUntilIdle(cap: Double) async -> Spin {
        var spin = Spin()
        let startWall = ProbeMeter.wall(), startCPU = ProbeMeter.threadCPU()
        var quiet = 0
        while ProbeMeter.wall() - startWall < cap {
            let sliceCPU = ProbeMeter.threadCPU()
            try? await Task.sleep(for: .milliseconds(100))
            quiet = ProbeMeter.threadCPU() - sliceCPU < 0.001 ? quiet + 1 : 0
            if quiet >= 4 { spin.reachedIdle = true; break }
        }
        spin.wall = ProbeMeter.wall() - startWall
        spin.cpu = ProbeMeter.threadCPU() - startCPU
        return spin
    }

    @Test func probe() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: Self.key)
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: Self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let rows = Self.rows(count: Self.rowCount)

        let coordinator = TranscriptList.Coordinator(context: context)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.orderBack(nil)
        _ = await Self.spinUntilIdle(cap: 0.5)

        TranscriptText.resetMeasureStats()
        let rssBefore = ProbeMeter.footprintMiB()
        let feedWall = ProbeMeter.wall(), feedCPU = ProbeMeter.threadCPU()
        coordinator.update(rows: rows, context: context, insets: (0, 0))
        let feed = (wall: ProbeMeter.wall() - feedWall, cpu: ProbeMeter.threadCPU() - feedCPU)
        let open = await Self.spinUntilIdle(cap: Self.idleCap)
        let rssOpen = ProbeMeter.footprintMiB()
        let measuredOpen = Self.measuredRows(coordinator)

        // One jump to the top, then a short manual scroll down, timing each scroll callback.
        let clip = scroll.contentView
        func scrollTo(_ y: CGFloat) -> (wall: Double, cpu: Double) {
            let w = ProbeMeter.wall(), c = ProbeMeter.threadCPU()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            return (ProbeMeter.wall() - w, ProbeMeter.threadCPU() - c)
        }
        let top = scrollTo(0)
        var steps: [Double] = []
        for i in 1...20 { steps.append(scrollTo(CGFloat(i) * 400).wall * 1000) }
        let afterScroll = await Self.spinUntilIdle(cap: Self.idleCap)
        let rssAfter = ProbeMeter.footprintMiB()
        let measuredAfter = Self.measuredRows(coordinator)

        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        var lines = [
            "| metric | value |", "|---|---|",
            "| rows fed | \(Self.rowCount) |",
            "| update() main-thread cpu / wall (ms) | \(f(feed.cpu * 1000)) / \(f(feed.wall * 1000)) |",
            "| open: spin to idle, main-thread cpu (s) | \(f(open.cpu, 2)) |",
            "| open: spin wall (s), idle reached | \(f(open.wall, 2)), \(open.reachedIdle) |",
            "| rows with final height after open | \(measuredOpen.map(String.init) ?? "n/a") |",
            "| scroll to top callback cpu / wall (ms) | \(f(top.cpu * 1000)) / \(f(top.wall * 1000)) |",
            "| 20 x 400pt scroll callbacks avg / max wall (ms) | \(f(steps.reduce(0, +) / Double(steps.count))) / \(f(steps.max() ?? 0)) |",
            "| after scroll: spin cpu (s), idle reached | \(f(afterScroll.cpu, 2)), \(afterScroll.reachedIdle) |",
            "| rows with final height after scroll | \(measuredAfter.map(String.init) ?? "n/a") |",
            "| RSS footprint before / after open / after scroll (MiB) | \(f(rssBefore, 0)) / \(f(rssOpen, 0)) / \(f(rssAfter, 0)) |",
        ]
        if let stats = PrefetchProbeShim.stats { lines.append("| prefetchStats | \(stats(coordinator)) |") }
        if let stats = PrefetchProbeShim.premeasure { lines.append("| premeasureStats / measureStats | \(stats(coordinator)) |") }
        print("\nTranscriptPrefetchProbe (\(Self.rowCount) rows, 700x900 window)\n" + lines.joined(separator: "\n"))

        // Sanity only: the numbers above are the point, not a budget.
        #expect(open.wall < Self.idleCap + 5)
        #expect(top.wall < 5)
        Self.keepAlive.append((window, coordinator))
    }
}
#endif

/// ~60 large synthetic images through the real loader (inline base64, so no network). Reports the decoded
/// bytes the loader retains and the process footprint once.
///
/// Run: `swift test --filter ImageRSSProbe`
@MainActor
@Suite("ImageRSSProbe", .serialized)
struct ImageRSSProbe {
    static let count = 60

    /// A noisy-gradient RGB PNG so the decoder does real work.
    static func syntheticPNG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        for band in 0..<8 {
            context.setFillColor(CGColor(red: CGFloat(band) / 8, green: 0.5, blue: 1 - CGFloat(band) / 8, alpha: 1))
            context.fill(CGRect(x: 0, y: band * height / 8, width: width, height: height / 8))
        }
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func decodedBytes(_ loader: ArtifactImageLoader) -> Int {
        loader.images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    @Test func probe() async {
        let png = Self.syntheticPNG(width: 4000, height: 3000)
        let payload = png.base64EncodedString()
        // Distinct cache keys from one PNG: `stripDataURL` drops everything up to the first comma.
        let refs = (0..<Self.count).map { i in
            ImageRef(artifactId: nil, base64: "data:image/png;n=\(i);base64,\(payload)", url: nil, mimeType: "image/png",
                     alt: nil, width: 4000, height: 3000)
        }
        let loader = ArtifactImageLoader()
        let rssBefore = ProbeMeter.footprintMiB()
        let start = ProbeMeter.wall()
        for ref in refs { loader.load(ref, sessionKey: "agent:probe:main") }
        _ = await eventually(timeout: .seconds(90)) { loader.images.count + loader.failures.count >= refs.count || loader.failures.count == refs.count }
        // Loaders that evict never reach `count`; let in-flight work drain.
        try? await Task.sleep(for: .seconds(1))
        let wall = ProbeMeter.wall() - start
        let rssAfter = ProbeMeter.footprintMiB()
        // Downscaling every retained image into a 16x16 bitmap reads all its pixels, like showing it would,
        // so lazily-backed pages count towards the footprint.
        let probe = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        probe.interpolationQuality = .medium
        for image in Array(loader.images.values) { probe.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16)) }
        let rssTouched = ProbeMeter.footprintMiB()
        let bytes = Self.decodedBytes(loader)
        var line = "ImageRSSProbe: \(Self.count) images of 4000x3000 (PNG \(png.count / 1024) KiB) → retained \(loader.images.count), "
            + "decoded \(bytes / 1_048_576) MiB, failed \(loader.failures.count), wall \(String(format: "%.1f", wall)) s, "
            + "RSS footprint \(Int(rssBefore)) → \(Int(rssAfter)) MiB (\(Int(rssTouched)) MiB after reading every pixel)"
        if let stats = PrefetchProbeShim.loaderStats { line += "; \(stats(loader))" }
        print("\n" + line)
        #expect(loader.failures.isEmpty)
    }
}
