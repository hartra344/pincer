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
        var clip: NSClipView { self.scroll.contentView }
        init(coordinator: TranscriptList.Coordinator, scroll: NSScrollView, window: NSWindow, table: NSTableView) {
            self.coordinator = coordinator
            self.scroll = scroll
            self.window = window
            self.table = table
        }
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
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: wide, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: wide, height: 900)
        window.orderBack(nil)
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 0.5)
        coordinator.update(rows: rows, context: context, insets: (0, 0))
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 20)
        Self.keepAlive.append((window, coordinator))
        return Host(coordinator: coordinator, scroll: scroll, window: window, table: scroll.documentView as! NSTableView)
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

    static func toggle(_ host: Host, name: String, to target: CGFloat, mid: Bool) async -> Toggle {
        var result = Toggle(name: name, finalWidth: target)
        let from = host.scroll.frame.width
        let anchor = mid ? midAnchor(host) : nil
        let gap0 = bottomGap(host)
        let stats0 = host.coordinator.prefetchStats.rowsMeasured
        let builds0 = builds(host)
        var cpus: [Double] = []
        for i in 1...frames {
            let width = from + (target - from) * CGFloat(i) / CGFloat(frames)
            let cpu = ProbeMeter.threadCPU()
            setWidth(host, width.rounded())
            try? await Task.sleep(for: .milliseconds(8))
            cpus.append(ProbeMeter.threadCPU() - cpu)
        }
        result.buildsDuringFrames = builds(host) - builds0
        result.measuredDuringFrames = host.coordinator.prefetchStats.rowsMeasured - stats0
        result.frameCPUMax = (cpus.max() ?? 0) * 1000
        result.frameCPUAvg = cpus.reduce(0, +) / Double(cpus.count) * 1000

        let settleStart = ProbeMeter.threadCPU()
        let buildsFrames = builds(host), measuredFrames = host.coordinator.prefetchStats.rowsMeasured
        // Thaw happens ~0.1 s after the last change; look at the builds by 0.3 s, then let prefetch drain.
        try? await Task.sleep(for: .milliseconds(300))
        result.buildsAfterThaw = builds(host) - buildsFrames
        result.measuredAfterThaw = host.coordinator.prefetchStats.rowsMeasured - measuredFrames
        await waitQuiet(host, minimum: 0)
        result.buildsTail = builds(host) - buildsFrames - result.buildsAfterThaw
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
        var lines = ["| toggle | builds in frames | builds after thaw (+0.3s) | builds tail | rowsMeasured frames/thaw | frame cpu max/avg ms | settle cpu ms | anchor drift pt | stale rows |",
                     "|---|---|---|---|---|---|---|---|---|"]
        for t in toggles {
            lines.append("| \(t.name) | \(t.buildsDuringFrames) | \(t.buildsAfterThaw) | \(t.buildsTail) | \(t.measuredDuringFrames)/\(t.measuredAfterThaw) | \(f(t.frameCPUMax))/\(f(t.frameCPUAvg)) | \(f(t.settleCPU)) | \(f(t.anchorDrift)) | \(t.staleVisibleRows)/\(t.visibleRows) |")
        }
        print("\nPanelSlideProbe \(label) (20k rows, \(Int(wide))<->\(Int(narrow)), \(frames) frames @ 8 ms)\n" + lines.joined(separator: "\n"))
    }

    static func check(_ toggles: [Toggle]) {
        for t in toggles {
            #expect(t.buildsDuringFrames <= 2, "\(t.name): layout builds during frames")
            #expect(t.buildsAfterThaw > 0, "\(t.name): one relayout after the width settles")
            #expect(t.buildsAfterThaw <= 120, "\(t.name): relayout bounded by ~1 screen either side of the viewport")
            #expect(t.anchorDrift <= 1, "\(t.name): anchor moved \(t.anchorDrift) pt")
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
        let open = await Self.toggle(host, name: "sidebar open \(Int(Self.wide))->\(Int(Self.narrow))", to: Self.narrow, mid: true)
        let close = await Self.toggle(host, name: "sidebar close \(Int(Self.narrow))->\(Int(Self.wide))", to: Self.wide, mid: true)
        Self.table("mid-transcript", [open, close])
        Self.check([open, close])
    }
}
#endif
