import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite("TranscriptPremeasure", .serialized)
struct TranscriptPremeasureTests {
    static let sources = [
        "Plain paragraph with **bold**, _italic_ and `code` that wraps across a few lines when the column is narrow enough to force it.",
        "# Heading\n\n- one\n- two with a longer item that should wrap at small widths\n  - nested\n\n1. first\n2. second",
        "> A quote that is long enough to wrap when the width is small, and keeps wrapping past that.\n\n```swift\nlet x = 1\n```\n\n---\n\nafter",
    ]

    private func premeasure(_ source: String, tone: TranscriptText.Tone, width: CGFloat) async -> PremeasuredRow {
        let key = PremeasureKey(source: source, tone: tone, styleGeneration: TranscriptStyle.generation, dark: false)
        let job = PremeasureJob(rowId: "r", bodies: [key], contentWidth: width, epoch: 0)
        let env = TextBuildEnvironment.current(dark: false)
        return await withCheckedContinuation { continuation in
            TranscriptPremeasurer.shared.submit([job], env: env, epoch: TranscriptPremeasureEpoch()) { rows in
                continuation.resume(returning: rows[0])
            }
        }
    }

    @Test func workerSizesMatchMainSizes() async {
        for source in Self.sources {
            for width in [320, 480, 700, 1100] as [CGFloat] {
                let row = await premeasure(source, tone: .primary, width: width)
                let body = try! #require(row.bodies.first)
                let main = TranscriptText.markdown(source, tone: .primary, dark: false)
                #expect(body.segments.count == main.count)
                for height in body.heights {
                    let text: NSAttributedString
                    switch main[height.index] {
                    case let .text(string), let .quote(string), let .code(_, _, string): text = string
                    default: continue
                    }
                    let size = TranscriptText.size(text, width: height.width, exact: height.exact)
                    #expect(size.height == height.height && size.width == height.usedWidth)
                }
            }
        }
    }

    @Test func adoptingResultsMakesTheTextWarm() async {
        let source = "Warm me **up**, then measure me again without TextKit. " + String(repeating: "word ", count: 80)
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: TranscriptStyle.generation, dark: false)
        let width: CGFloat = 640
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        #expect(!TranscriptText.isWarm(key.textKey, contentWidth: contentWidth))
        let driver = TranscriptPremeasureDriver()
        let row = await premeasure(source, tone: .primary, width: contentWidth)
        #expect(driver.adopt([row], width: width, epoch: driver.epoch.current) == ["r"])
        #expect(TranscriptText.isWarm(key.textKey, contentWidth: contentWidth))
        let before = TranscriptText.measureStats
        for segment in TranscriptText.markdown(source, tone: .primary, dark: false) {
            if case let .text(text) = segment { _ = TranscriptText.size(text, width: contentWidth, memoized: true) }
        }
        #expect(TranscriptText.measureStats.mainLayouts == before.mainLayouts)
        #expect(TranscriptText.measureStats.memoHits > before.memoHits)
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > 0)
    }

    @Test func tableCellsMatchMainAndWarmTheRow() async {
        let source = "| Name | Notes |\n|---|---:|\n| alpha | a fairly long note that has to wrap in a narrow column, more than once |\n| beta | short |"
        let width: CGFloat = 640
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        let row = await premeasure(source, tone: .primary, width: contentWidth)
        let body = try! #require(row.bodies.first)
        #expect(!body.cells.isEmpty)
        let driver = TranscriptPremeasureDriver()
        #expect(driver.adopt([row], width: width, epoch: driver.epoch.current) == ["r"])
        let key = body.key.textKey
        #expect(TranscriptText.isWarm(key, contentWidth: contentWidth))
        let main = TranscriptText.markdown(source, tone: .primary, dark: false)
        guard case let .table(table) = main.first(where: { if case .table = $0 { true } else { false } })! else { return }
        let before = TranscriptText.measureStats.mainLayouts
        var naturals = Array(repeating: CGFloat(0), count: table.cells[0].count)
        for cells in table.cells { for (column, cell) in cells.enumerated() { naturals[column] = max(naturals[column], TranscriptText.naturalWidth(cell, memoized: true)) } }
        let widths = TranscriptTableMetrics.columnWidths(naturals: naturals, available: contentWidth)
        for cells in table.cells {
            for (column, cell) in cells.enumerated() {
                _ = TranscriptText.size(cell, width: max(widths[column] - TranscriptTableMetrics.padding, 1), memoized: true)
            }
        }
        #expect(TranscriptText.measureStats.mainLayouts == before)
        for cell in body.cells {
            let text = table.cells[cell.row][cell.column]
            #expect(TranscriptText.size(text, width: cell.width).height == cell.height)
            #expect(TranscriptText.naturalWidth(text) == cell.natural)
        }
    }

    @Test func resultsFromAnOlderEpochOrWidthAreDropped() async {
        let driver = TranscriptPremeasureDriver()
        let row = await premeasure("Stale **result**", tone: .primary, width: TranscriptMetrics.contentWidth(rowWidth: 640))
        let old = driver.epoch.current
        driver.cancelAll()
        #expect(driver.adopt([row], width: 640, epoch: old).isEmpty)
        #expect(driver.adopt([row], width: 500, epoch: driver.epoch.current).isEmpty)
        #expect(driver.stats.discardedStale == 2 && driver.stats.adopted == 0)
    }

    @Test func darkAppearanceKeysTheSegmentCache() {
        let source = "Cost is $\\pi r^2$ here"
        let light = TranscriptText.markdown(source, tone: .primary, dark: false)
        let dark = TranscriptText.markdown(source, tone: .primary, dark: true)
        guard case let .text(a) = light[0], case let .text(b) = dark[0] else { Issue.record("expected text"); return }
        #expect(a !== b)
    }
}

#if os(macOS)
/// A hosted macOS list, for counter-based checks of the off-main path (no wall-clock assertions).
@MainActor
@Suite("TranscriptPremeasureHosted", .serialized)
struct TranscriptPremeasureHostedTests {
    /// Tearing the table down mid-test crashes AppKit; the tests leak their windows instead.
    static var keepAlive: [(NSWindow, TranscriptList.Coordinator)] = []

    @MainActor struct Host {
        let coordinator: TranscriptList.Coordinator
        let scroll: NSScrollView
        let context: TranscriptContext
        var clip: NSClipView { self.scroll.contentView }
    }

    static func makeHost() async -> Host {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:probe:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let coordinator = TranscriptList.Coordinator(context: context)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.orderBack(nil)
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 0.5)
        Self.keepAlive.append((window, coordinator))
        return Host(coordinator: coordinator, scroll: scroll, context: context)
    }

    /// The coordinator's driver, owned by the shared controller.
    static func driver(_ coordinator: TranscriptList.Coordinator) -> TranscriptPremeasureDriver {
        coordinator.controller.premeasure
    }

    static func assistant(_ id: String, text: String, streaming: Bool = false, at n: Int) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        turn.isStreaming = streaming
        return .entry(.assistant(turn))
    }

    /// `TranscriptPrefetchProbe.rows` with `salt` in every text and id, so its text isn't already in the process-wide caches.
    static func rows(count: Int, salt: String, from start: Int = 0) -> [TranscriptRow] {
        TranscriptPrefetchProbe.rows(count: count).map { row in
            switch row {
            case let .entry(.user(item)):
                var out = ChatItem(id: salt + item.id, role: .user, blocks: item.blocks.map { block in
                    if case let .text(text) = block { return .text(salt + " " + text) }
                    return block
                }, timestamp: item.timestamp)
                out.transcriptId = out.id
                return .entry(.user(out))
            case let .entry(.assistant(turn)):
                var out = AssistantTurn(id: salt + turn.id, timestamp: turn.timestamp)
                out.text = turn.text.map { salt + " " + $0 }
                out.textTimestamps = turn.textTimestamps
                out.textModelNames = turn.textModelNames
                out.textIds = [salt + turn.id]
                return .entry(.assistant(out))
            default:
                return row
            }
        }
    }

    static func idle(_ host: Host, cap: Double = 20) async {
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: cap)
        _ = await eventually(timeout: .seconds(5)) { Self.driver(host.coordinator).inFlightCount == 0 }
    }

    @Test func scrollingWithinThePrefetchedWindowDoesNoMainTextKit() async {
        let host = await Self.makeHost()
        let table = host.scroll.documentView as! NSTableView
        let offBefore = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        TranscriptText.resetMeasureStats()
        host.coordinator.update(rows: Self.rows(count: 3000, salt: "s1"), context: host.context, insets: (0, 0))
        await Self.idle(host)
        let open = TranscriptText.measureStats
        let offAfterOpen = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        #expect(offAfterOpen > offBefore, "open: the worker measured rows")
        #expect(host.coordinator.premeasureStats.adopted > 0)
        #expect(open.memoHits > 0, "open: warmed rows reuse the worker's sizes")

        func scrollSteps(_ steps: Int) -> (mainLayouts: Int, memoHits: Int) {
            TranscriptText.resetMeasureStats()
            var y = host.clip.bounds.minY
            for _ in 0..<steps {
                y -= 100
                host.clip.scroll(to: NSPoint(x: 0, y: y))
                host.scroll.reflectScrolledClipView(host.clip)
            }
            return TranscriptText.measureStats
        }
        // Every row is eligible text/markdown, so the budget for main-thread layouts is zero.
        let near = scrollSteps(40)
        // A jump far outside the window, let the prefetch follow it (worker), then scroll inside the new window.
        host.clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 1500).minY))
        host.scroll.reflectScrolledClipView(host.clip)
        let offloadedBeforeJump = host.coordinator.premeasureStats.offloaded
        // A programmatic scroll doesn't restart the idle prefetch; the end of a live scroll does.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: host.scroll)
        await Self.idle(host)
        let jumped = host.coordinator.premeasureStats
        let far = scrollSteps(40)
        print("\nTranscriptPremeasure scroll (3000 rows): open mainLayouts \(open.mainLayouts) memoHits \(open.memoHits); "
            + "scroll near window: mainLayouts \(near.mainLayouts) memoHits \(near.memoHits); "
            + "after jump: offloaded \(offloadedBeforeJump) -> \(jumped.offloaded), scroll mainLayouts \(far.mainLayouts) memoHits \(far.memoHits); "
            + "premeasureStats \(host.coordinator.premeasureStats); offMainLayouts \(offAfterOpen)")
        #expect(near.mainLayouts == 0, "scrolling inside the prefetched window ran \(near.mainLayouts) TextKit layouts on main")
        #expect(jumped.offloaded > offloadedBeforeJump, "the prefetch offloads rows around the new position")
        #expect(far.mainLayouts == 0, "scrolling inside the window after a jump ran \(far.mainLayouts) TextKit layouts on main")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
    }

    @Test func ineligibleRowsAreNeverOffloaded() async {
        let host = await Self.makeHost()
        let count = 300
        var rows = Self.rows(count: count, salt: "s2")
        let streamingIndex = count - 1, mathIndex = count - 17, findIndex = count - 9, controlIndex = count - 13
        let body = String(repeating: "filler words that wrap ", count: 12)
        rows[streamingIndex] = Self.assistant("stream", text: "Streaming reply " + body, streaming: true, at: streamingIndex)
        rows[mathIndex] = Self.assistant("math", text: "Energy scales as $x^2$ and \\(y^3\\) here. " + body, at: mathIndex)
        rows[findIndex] = Self.assistant("find", text: "Find the needle in this reply. " + body, at: findIndex)
        rows[controlIndex] = Self.assistant("control", text: "Plain reply " + body, at: controlIndex)
        var highlight = TranscriptHighlight()
        highlight.query = "needle"
        highlight.rows = ["a-find"]
        host.coordinator.apply(highlight)

        let renderer = host.coordinator.renderer
        #expect(renderer.premeasureBodies(for: rows[streamingIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[mathIndex]) != nil)
        #expect(renderer.premeasureBodies(for: rows[findIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[controlIndex]) != nil)

        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        await Self.idle(host)
        #if DEBUG
        let offloaded = Self.driver(host.coordinator).offloadedIds
        #expect(offloaded.contains("a-control"), "eligible neighbours are offloaded")
        #expect(!offloaded.contains("a-stream"))
        #expect(offloaded.contains("a-math"), "rows with inline math are offloaded too (#432)")
        #expect(!offloaded.contains("a-find"))
        #endif
    }

    @Test func streamingUpdatesAndUnchangedHighlightDoNotStallThePrefetch() async {
        let host = await Self.makeHost()
        var rows = Self.rows(count: 1500, salt: "s4")
        rows.append(Self.assistant("live", text: "Streaming", streaming: true, at: rows.count))
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // updateNSView re-applies the (unchanged) highlight on every flush; the flushes must not cancel the worker.
        for step in 0..<60 {
            rows[rows.count - 1] = Self.assistant("live", text: "Streaming " + String(repeating: "token ", count: step + 1),
                                                  streaming: true, at: rows.count - 1)
            host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
            host.coordinator.apply(TranscriptHighlight())
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Self.idle(host)
        let stats = host.coordinator.premeasureStats
        print("\nTranscriptPremeasure streaming: premeasureStats \(stats)")
        #expect(stats.adopted > 0, "results were adopted while the last row streamed")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #if DEBUG
        #expect(!Self.driver(host.coordinator).offloadedIds.contains("a-live"))
        #endif
    }

    @Test func workerMeasuresOffMainWithoutMainTextKit() async {
        // `TranscriptPremeasurer.measure` asserts `.notOnQueue(.main)` in DEBUG, and only it bumps `offMainLayouts`.
        let off = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        TranscriptText.resetMeasureStats()
        let source = "Worker **only** text. " + String(repeating: "word ", count: 60)
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: TranscriptStyle.generation, dark: false)
        let job = PremeasureJob(rowId: "w", bodies: [key], contentWidth: 500, epoch: 0)
        let env = TextBuildEnvironment.current(dark: false)
        let rows = await withCheckedContinuation { continuation in
            TranscriptPremeasurer.shared.submit([job], env: env, epoch: TranscriptPremeasureEpoch()) { continuation.resume(returning: $0) }
        }
        #expect(rows.first?.bodies.isEmpty == false)
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > off)
        #expect(TranscriptText.measureStats.mainLayouts == 0)
    }

    @Test func pagingOlderRowsAndTrimmingWhileJobsAreInFlightLeavesNothingInFlight() async {
        let host = await Self.makeHost()
        let rows = Self.rows(count: 3000, salt: "s3")
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // Catch jobs on the worker, then reshape the list under them.
        _ = await eventually(timeout: .seconds(2)) { Self.driver(host.coordinator).inFlightCount > 0 }
        let sawInFlight = Self.driver(host.coordinator).inFlightCount > 0
        let older = Self.rows(count: 100, salt: "s3old")
        host.coordinator.update(rows: older + rows, context: host.context, insets: (0, 0))
        host.coordinator.update(rows: Array((older + rows).dropFirst(150)), context: host.context, insets: (0, 0))
        await Self.idle(host)
        print("\nTranscriptPremeasure windowing: jobs were in flight at reshape \(sawInFlight); premeasureStats \(host.coordinator.premeasureStats)")
        #expect(sawInFlight, "the test reshaped the list while jobs were in flight")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #expect(Self.driver(host.coordinator).inFlight.isEmpty)
    }
}
#endif
