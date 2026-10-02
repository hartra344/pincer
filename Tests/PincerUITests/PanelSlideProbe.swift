import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit

/// #347: a sidebar/inspector slide changes the transcript width every frame. The transcript must not
/// re-lay out per frame; it lays out once, around the viewport, when the width settles.
///
/// Run: `swift test --filter PanelSlideProbe`
@MainActor
@Suite("PanelSlideProbe", .serialized)
struct PanelSlideProbe {
    static let frames = 20
    static let wide: CGFloat = 900
    static let narrow: CGFloat = 640
    /// Tearing the table down mid-test crashes AppKit; the probe leaks its windows instead.
    static var keepAlive: [(NSWindow, TranscriptList.Coordinator)] = []

    struct Toggle {
        var name = ""
        var buildsDuringFrames = 0
        var buildsAfterThaw = 0
        var buildsTail = 0
        var measuredDuringFrames = 0
        var measuredAfterThaw = 0
        var offloadedDuringFrames = 0
        var offloadedAtThaw = 0
        var midSlideThaws = 0
        var thawed = false
        var frameCPUMax = 0.0
        var frameCPUAvg = 0.0
        var settleCPU = 0.0
        var anchorDrift = 0.0
        var staleVisibleRows = 0
        var visibleRows = 0
        var finalWidth: CGFloat = 0
    }

    final class Host {
        let coordinator: TranscriptList.Coordinator
        let scroll: NSScrollView
        let window: NSWindow
        let table: NSTableView
        let context: TranscriptContext
        var clip: NSClipView { self.scroll.contentView }
        init(coordinator: TranscriptList.Coordinator, scroll: NSScrollView, window: NSWindow,
             table: NSTableView, context: TranscriptContext) {
            self.coordinator = coordinator
            self.scroll = scroll
            self.window = window
            self.table = table
            self.context = context
        }
    }

    /// Lets the probe hold AppKit's public live-resize state through a quiet pause without KVC or
    /// a real mouse drag, which is not deterministic in a headless test runner.
    final class ProbeResizeWindow: NSWindow {
        var resizingForProbe = false
        override var inLiveResize: Bool { self.resizingForProbe }
    }

    static func makeHost(rows: [TranscriptRow]) async -> Host {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:probe:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let coordinator = TranscriptList.Coordinator(context: context)
        let scroll = coordinator.makeScrollView()
        let window = ProbeResizeWindow(contentRect: NSRect(x: -4000, y: -4000, width: wide, height: 900),
                                       styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: wide, height: 900)
        scroll.autoresizingMask = [.width, .height]
        window.orderBack(nil)
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 0.5)
        coordinator.update(rows: rows, context: context, insets: (0, 0))
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 20)
        Self.keepAlive.append((window, coordinator))
        return Host(coordinator: coordinator, scroll: scroll, window: window,
                    table: scroll.documentView as! NSTableView, context: context)
    }

    /// Layout builds so far: the coder's `layoutBuildCount`, else the renderer's private `serial` (same thing today).
    static func builds(_ host: Host) -> Int {
        let children = Mirror(reflecting: host.coordinator.renderer).children
        for label in ["layoutBuildCount", "serial"] {
            if let value = children.first(where: { $0.label == label })?.value as? Int { return value }
        }
        Issue.record("no layout build counter found on TranscriptRenderer")
        return 0
    }

    static func setWidth(_ host: Host, _ width: CGFloat) {
        var frame = host.scroll.frame
        frame.size.width = width
        host.scroll.frame = frame
    }

    /// Resizes the actual hosted window so AppKit delivers the same scroll/clip frame changes as
    /// a window resize, rather than changing the scroll view's frame directly.
    static func setWindowContentWidth(_ host: Host, _ width: CGFloat) {
        var frame = host.window.frame
        frame.size.width += width - host.scroll.frame.width
        host.window.setFrame(frame, display: false, animate: false)
        host.window.contentView?.layoutSubtreeIfNeeded()
        host.scroll.layoutSubtreeIfNeeded()
        host.clip.layoutSubtreeIfNeeded()
    }

    /// Row at the middle of the viewport (the coordinator's anchor row) and its top offset within the viewport.
    static func midAnchor(_ host: Host) -> (row: Int, offset: CGFloat) {
        let bounds = host.clip.bounds
        let row = host.table.row(at: NSPoint(x: 1, y: bounds.midY))
        return (row, host.table.rect(ofRow: row).minY - bounds.minY)
    }

    static func bottomGap(_ host: Host) -> CGFloat {
        let table = host.table
        let last = table.numberOfRows - 1
        let bounds = host.clip.bounds
        return table.rect(ofRow: last).maxY + host.scroll.contentInsets.bottom - bounds.maxY
    }

    /// Visible rows whose cell content isn't laid out at the current clip width.
    static func staleRows(_ host: Host) -> (stale: Int, visible: Int) {
        let visible = host.table.rows(in: host.table.visibleRect)
        var stale = 0
        for row in visible.location..<(visible.location + visible.length) {
            guard let cell = host.table.view(atColumn: 0, row: row, makeIfNecessary: false),
                  let content = cell.subviews.first else { continue }
            if abs(content.frame.width - host.clip.bounds.width) > 0.5 { stale += 1 }
        }
        return (stale, visible.length)
    }

    /// Waits until layout builds stop for 3 polls in a row (and at least `minimum` seconds), capped at 2 s.
    @discardableResult
    static func waitQuiet(_ host: Host, minimum: Double = 0.3) async -> Double {
        let start = ProbeMeter.wall()
        var last = builds(host), quiet = 0
        while ProbeMeter.wall() - start < 2 {
            try? await Task.sleep(for: .milliseconds(60))
            let now = builds(host)
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 3, ProbeMeter.wall() - start >= minimum { break }
        }
        return ProbeMeter.wall() - start
    }

    /// Waits until the anchor row sits at the same spot for 5 polls (20 ms apart) while no layout build
    /// lands in between, capped at 5 s. The builds counter alone can look quiet for 180 ms on a starved
    /// runner while a height fix or prefetch turn is still queued on the main loop; each of those ends
    /// with the coordinator putting the anchor back, so the position is what says it has finished.
    static func waitAnchorStable(_ host: Host, row: Int?) async {
        func position() -> CGFloat {
            let r = row ?? host.table.numberOfRows - 1
            return host.table.rect(ofRow: r).minY - host.clip.bounds.minY
        }
        let start = ProbeMeter.wall()
        var last = position(), lastBuilds = builds(host), stable = 0
        while stable < 5, ProbeMeter.wall() - start < 5 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = position(), nowBuilds = builds(host)
            stable = now == last && nowBuilds == lastBuilds ? stable + 1 : 0
            last = now
            lastBuilds = nowBuilds
        }
    }

    /// Polls (every 5 ms, up to 10 s) until a thaw after `thaws` has run and the width is no longer frozen.
    static func waitUntilThawed(_ host: Host, after thaws: Int) async -> Bool {
        func thawed() -> Bool { !host.coordinator.isWidthFrozen && host.coordinator.thawStats.count > thaws }
        let start = ProbeMeter.wall()
        while !thawed(), ProbeMeter.wall() - start < 10 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return thawed()
    }

    static func toggle(_ host: Host, name: String, to target: CGFloat, mid: Bool) async -> Toggle {
        var result = Toggle(name: name, finalWidth: target)
        let from = host.scroll.frame.width
        let anchor = mid ? midAnchor(host) : nil
        let gap0 = bottomGap(host)
        let stats0 = host.coordinator.prefetchStats.rowsMeasured
        let builds0 = builds(host)
        let thaws0 = host.coordinator.thawStats.count
        var cpus: [Double] = []
        for i in 1...frames {
            let width = from + (target - from) * CGFloat(i) / CGFloat(frames)
            let cpu = ProbeMeter.threadCPU()
            let before = builds(host), measuredBefore = host.coordinator.prefetchStats.rowsMeasured
            let offloadedBefore = host.coordinator.premeasureStats.offloaded
            setWidth(host, width.rounded())
            try? await Task.sleep(for: .milliseconds(8))
            cpus.append(ProbeMeter.threadCPU() - cpu)
            // A stalled runner can leave > 0.1 s between two frames, so the (correct) thaw runs mid-slide.
            // Only work done while the width is still frozen counts against the frames.
            if host.coordinator.isWidthFrozen {
                result.buildsDuringFrames += builds(host) - before
                result.measuredDuringFrames += host.coordinator.prefetchStats.rowsMeasured - measuredBefore
                result.offloadedDuringFrames += host.coordinator.premeasureStats.offloaded - offloadedBefore
            } else {
                result.midSlideThaws += 1
            }
        }
        result.frameCPUMax = (cpus.max() ?? 0) * 1000
        result.frameCPUAvg = cpus.reduce(0, +) / Double(cpus.count) * 1000

        let settleStart = ProbeMeter.threadCPU()
        let offloadedFrames = host.coordinator.premeasureStats.offloaded
        // Await the thaw's relayout at the final width (#401). A stalled runner can leave > 0.1 s after
        // the last frame, so it may already have run inside the frame loop: read what the thaw itself
        // did instead of the builds seen in a window after the loop. Later builds are prefetch.
        result.thawed = await Self.waitUntilThawed(host, after: thaws0)
        let thaw = host.coordinator.thawStats
        result.buildsAfterThaw = thaw.builds
        result.measuredAfterThaw = thaw.rowsMeasured
        result.offloadedAtThaw = host.coordinator.premeasureStats.offloaded - offloadedFrames
        await waitQuiet(host, minimum: 0)
        await waitAnchorStable(host, row: anchor?.row)
        result.buildsTail = builds(host) - thaw.buildsAfter
        result.settleCPU = (ProbeMeter.threadCPU() - settleStart) * 1000

        let stale = staleRows(host)
        result.staleVisibleRows = stale.stale
        result.visibleRows = stale.visible
        if let anchor {
            let offset = host.table.rect(ofRow: anchor.row).minY - host.clip.bounds.minY
            result.anchorDrift = abs(offset - anchor.offset)
        } else {
            result.anchorDrift = abs(bottomGap(host) - gap0)
        }
        return result
    }

    static func table(_ label: String, _ toggles: [Toggle]) {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var lines = ["| toggle | builds in frames | builds at thaw | builds tail | rowsMeasured frames/thaw | frame cpu max/avg ms | settle cpu ms | anchor drift pt | stale rows | mid-slide thaws | offloaded frames/after |",
                     "|---|---|---|---|---|---|---|---|---|---|---|"]
        for t in toggles {
            lines.append("| \(t.name) | \(t.buildsDuringFrames) | \(t.buildsAfterThaw) | \(t.buildsTail) | \(t.measuredDuringFrames)/\(t.measuredAfterThaw) | \(f(t.frameCPUMax))/\(f(t.frameCPUAvg)) | \(f(t.settleCPU)) | \(f(t.anchorDrift)) | \(t.staleVisibleRows)/\(t.visibleRows) | \(t.midSlideThaws) | \(t.offloadedDuringFrames)/\(t.offloadedAtThaw) |")
        }
        print("\nPanelSlideProbe \(label) (20k rows, \(Int(wide))<->\(Int(narrow)), \(frames) frames @ 8 ms)\n" + lines.joined(separator: "\n"))
    }

    static func check(_ toggles: [Toggle]) {
        for t in toggles {
            #expect(t.buildsDuringFrames <= 2, "\(t.name): layout builds during frames")
            #expect(t.offloadedDuringFrames == 0, "\(t.name): \(t.offloadedDuringFrames) rows sent to the worker while the width was frozen")
            #expect(t.thawed, "\(t.name): the width thaws once it settles")
            #expect(t.buildsAfterThaw > 0, "\(t.name): one relayout after the width settles")
            #expect(t.buildsAfterThaw <= 120, "\(t.name): relayout bounded by ~1 screen either side of the viewport")
            // The coordinator skips re-anchoring when the clip is within 0.5 pt of the target
            // (TranscriptList.Coordinator.restore), so the position captured before the slide and the one
            // read after it can each be off by up to 0.5 pt: 1 pt in total. Anything beyond that is a
            // real move, not rounding (the clip keeps fractional offsets, no backing-pixel snapping).
            #expect(t.anchorDrift <= 1 + 1e-6, "\(t.name): anchor moved \(t.anchorDrift) pt")
            #expect(t.staleVisibleRows == 0, "\(t.name): visible rows not at the final clip width")
        }
    }

    @Test func bottomAnchored() async {
        let host = await Self.makeHost(rows: TranscriptPrefetchProbe.rows(count: TranscriptPrefetchProbe.rowCount))
        let open = await Self.toggle(host, name: "sidebar open \(Int(Self.wide))->\(Int(Self.narrow))", to: Self.narrow, mid: false)
        let close = await Self.toggle(host, name: "sidebar close \(Int(Self.narrow))->\(Int(Self.wide))", to: Self.wide, mid: false)
        Self.table("bottom-anchored", [open, close])
        Self.check([open, close])
    }

    @Test func midTranscriptAnchor() async {
        let host = await Self.makeHost(rows: TranscriptPrefetchProbe.rows(count: TranscriptPrefetchProbe.rowCount))
        host.clip.scroll(to: NSPoint(x: 0, y: host.table.rect(ofRow: 10_000).minY))
        host.scroll.reflectScrolledClipView(host.clip)
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 10)
        await Self.waitQuiet(host)
        // Nudge so the coordinator's anchor is the row at the middle of the settled viewport.
        host.clip.scroll(to: NSPoint(x: 0, y: host.clip.bounds.minY + 1))
        host.scroll.reflectScrolledClipView(host.clip)
        await Self.waitQuiet(host)
        await Self.waitAnchorStable(host, row: Self.midAnchor(host).row)
        let open = await Self.toggle(host, name: "sidebar open \(Int(Self.wide))->\(Int(Self.narrow))", to: Self.narrow, mid: true)
        let close = await Self.toggle(host, name: "sidebar close \(Int(Self.narrow))->\(Int(Self.wide))", to: Self.wide, mid: true)
        Self.table("mid-transcript", [open, close])
        Self.check([open, close])
    }

    @Test func liveResizeWaitsPastQuietPauseAndThawsStreamingTailOnce() async throws {
        let rows = Self.streamingTail(TranscriptPrefetchProbe.rows(count: 400), append: "")
        let host = await Self.makeHost(rows: rows)
        let window = try #require(host.window as? ProbeResizeWindow)
        let originalWidth = host.scroll.frame.width
        let gapBefore = Self.bottomGap(host)
        let initialBuilds = Self.builds(host)
        let initialThaws = host.coordinator.thawStats.count

        window.resizingForProbe = true
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for width in [originalWidth - 36, originalWidth - 72, originalWidth - 108] {
            Self.setWindowContentWidth(host, width)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.inLiveResize)
        #expect(host.coordinator.isWidthFrozen)
        #expect(Self.builds(host) == initialBuilds, "window width changes do not build transcript layouts during the drag")

        // Real users can pause while still holding the resize handle. The quiet timer must not thaw
        // while AppKit reports an active live resize; didEndLiveResize remains the authoritative end.
        try? await Task.sleep(for: .milliseconds(Int(TranscriptWidthFreeze.quietInterval * 2_000)))
        #expect(host.coordinator.isWidthFrozen, "an active window resize stays frozen past the quiet interval")
        #expect(host.coordinator.thawStats.count == initialThaws,
                "the quiet timer does not relayout while the window is still live-resizing")

        // Keep exercising the stream-at-frozen-width case on the baseline too, even though its
        // quiet timer currently thaws early: a new native width change starts a fresh freeze.
        let finalWidth = originalWidth - 132
        Self.setWindowContentWidth(host, finalWidth)
        #expect(abs(host.scroll.frame.width - finalWidth) <= 0.5)
        let streamedRows = Self.streamingTail(rows, append: String(repeating: " streamed words", count: 220))
        host.coordinator.update(rows: streamedRows, context: host.context, insets: (0, 0))
        #expect(host.coordinator.isWidthFrozen, "a same-ID streaming tail updates while the resize width is frozen")

        let buildsBeforeEnd = Self.builds(host)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(Self.builds(host) == buildsBeforeEnd, "no additional layout work occurs before the resize ends")
        window.resizingForProbe = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)

        #expect(host.coordinator.thawStats.count == initialThaws + 1,
                "the live resize causes exactly one thaw after its end notification")
        #expect(!host.coordinator.isWidthFrozen)
        #expect(abs(host.scroll.frame.width - finalWidth) <= 0.5)
        let finalLayoutWidth = host.clip.bounds.width
        let last = try #require(streamedRows.last)
        let measured = try #require(host.coordinator.controller.heights[last.id])
        let expectedHeight = host.coordinator.renderer.layout(for: last, width: finalLayoutWidth).height
        #expect(measured.isCurrent(at: finalLayoutWidth), "the streamed tail is measured at the final window width")
        #expect(abs(measured.value - expectedHeight) <= 0.5, "the streamed tail has its final-width height")
        #expect(abs(Self.bottomGap(host) - gapBefore) <= 1, "the reader remains bottom-anchored through the stream and thaw")
    }

    static func streamingTail(_ rows: [TranscriptRow], append: String) -> [TranscriptRow] {
        guard let last = rows.last, case let .entry(.assistant(original)) = last else {
            Issue.record("the live-resize fixture must end with an assistant turn")
            return rows
        }
        var turn = original
        turn.isStreaming = true
        if !append.isEmpty, !turn.text.isEmpty {
            turn.text[turn.text.count - 1] += append
        }
        var result = rows
        result[result.count - 1] = .entry(.assistant(turn))
        return result
    }
}
#endif
