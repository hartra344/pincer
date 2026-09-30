#if os(iOS)
import CoreGraphics
import Foundation
@testable import PincerKit
import Testing
import UIKit
@testable import PincerUI

/// The UIKit counterpart of `TranscriptPremeasureHosted` (#434): a hosted `UICollectionView` list with counter-based
/// checks of the off-main path (no wall-clock assertions). Scrolling is driven through `readerScrolled`, which is what
/// `scrollViewDidScroll` calls for a real drag.
@MainActor
@Suite("TranscriptPremeasureHostedUIKit", .serialized)
struct TranscriptUIKitHostedTests {
    /// Tearing the collection view down mid-test is avoided the same way as on macOS: the tests keep their windows.
    static var keepAlive: [(UIWindow, TranscriptList.Coordinator)] = []

    @MainActor struct Host {
        let coordinator: TranscriptList.Coordinator
        let view: UICollectionView
        let context: TranscriptContext
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
        let view = coordinator.makeCollectionView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        Self.keepAlive.append((window, coordinator))
        return Host(coordinator: coordinator, view: view, context: context)
    }

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

    /// Alternating user and assistant rows with `salt` in every text and id, so the text isn't already in the
    /// process-wide caches. Ids are `u<salt><n>` and `a<salt><n>`.
    static func rows(count: Int, salt: String, from start: Int = 0) -> [TranscriptRow] {
        let variants = (0..<16).map { StreamingProbe.reply(bytes: 150 + $0 * 90) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (start..<start + count).map { n in
            let stamp = base.addingTimeInterval(Double(n))
            if n % 2 == 0 {
                let text = "\(salt) Question \(n): \(variants[n % 16].prefix(120 + (n % 7) * 60))"
                var item = ChatItem(id: "u\(salt)\(n)", role: .user, blocks: [.text(text)], timestamp: stamp)
                item.transcriptId = item.id
                return .entry(.user(item))
            }
            var turn = AssistantTurn(id: "a\(salt)\(n)", timestamp: stamp)
            turn.text = ["\(salt) Reply \(n)\n\n" + variants[(n / 2) % 16]]
            turn.textTimestamps = [stamp]
            turn.textModelNames = [nil]
            turn.textIds = [turn.id]
            return .entry(.assistant(turn))
        }
    }

    /// Waits on state rather than time, so a slow runner only makes it longer: the worker has nothing in flight and the
    /// number of measured rows has held still for five 100 ms slices that used under 1 ms of main-thread CPU each
    /// (the prefetch is idle), or `cap` seconds pass.
    static func idle(_ host: Host, cap: Double = 90) async {
        let start = ProbeMeter.wall()
        var quiet = 0
        var measured = -1
        while ProbeMeter.wall() - start < cap {
            let slice = ProbeMeter.threadCPU()
            try? await Task.sleep(for: .milliseconds(100))
            let now = host.coordinator.controller.heights.values.filter(\.measured).count
            let still = now == measured && Self.driver(host.coordinator).inFlightCount == 0
            measured = now
            quiet = still && ProbeMeter.threadCPU() - slice < 0.001 ? quiet + 1 : 0
            if quiet >= 5 { break }
        }
        await Self.drained(host)
    }

    /// Waits for the worker to have nothing in flight.
    static func drained(_ host: Host) async {
        _ = await eventually(timeout: .seconds(30)) { Self.driver(host.coordinator).inFlightCount == 0 }
    }

    static func scrollSteps(_ host: Host, _ steps: Int) -> (mainLayouts: Int, memoHits: Int) {
        TranscriptText.resetMeasureStats()
        for _ in 0..<steps {
            host.view.contentOffset.y = max(host.view.contentOffset.y - 100, -host.view.adjustedContentInset.top)
            host.coordinator.controller.readerScrolled(movingUp: true)
            host.view.layoutIfNeeded()
        }
        return TranscriptText.measureStats
    }

    @Test func scrollingWithinThePrefetchedWindowDoesNoMainTextKit() async {
        let host = await Self.makeHost()
        let offBefore = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        TranscriptText.resetMeasureStats()
        host.coordinator.update(rows: Self.rows(count: 3000, salt: "k1"), context: host.context, insets: (0, 0))
        await Self.idle(host)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.adopted > 0 }
        let open = TranscriptText.measureStats
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > offBefore, "open: the worker measured rows")
        #expect(host.coordinator.premeasureStats.adopted > 0)
        #expect(open.memoHits > 0, "open: warmed rows reuse the worker's sizes")

        // Every row is eligible text/markdown, so the budget for main-thread layouts is zero.
        let rowsBefore = host.coordinator.visibleRows
        let near = Self.scrollSteps(host, 40)
        #expect(host.coordinator.visibleRows != rowsBefore, "the scroll moved the viewport")
        // A jump far outside the window, let the prefetch follow it (worker), then scroll inside the new window.
        let offloadedBeforeJump = host.coordinator.premeasureStats.offloaded
        let target = host.coordinator.rowTop(1500) ?? 0
        host.view.contentOffset.y = target
        host.coordinator.scrollViewDidEndDecelerating(host.view)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.offloaded > offloadedBeforeJump }
        await Self.idle(host)
        let jumped = host.coordinator.premeasureStats
        let far = Self.scrollSteps(host, 40)
        print("\nTranscriptPremeasure UIKit scroll (3000 rows): open mainLayouts \(open.mainLayouts) memoHits \(open.memoHits); "
            + "scroll near window: mainLayouts \(near.mainLayouts) memoHits \(near.memoHits); "
            + "after jump: offloaded \(offloadedBeforeJump) -> \(jumped.offloaded), scroll mainLayouts \(far.mainLayouts) memoHits \(far.memoHits); "
            + "premeasureStats \(host.coordinator.premeasureStats)")
        #expect(near.mainLayouts == 0, "scrolling inside the prefetched window ran \(near.mainLayouts) TextKit layouts on main")
        #expect(jumped.offloaded > offloadedBeforeJump, "the prefetch offloads rows around the new position")
        #expect(far.mainLayouts == 0, "scrolling inside the window after a jump ran \(far.mainLayouts) TextKit layouts on main")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
    }

    @Test func ineligibleRowsAreNeverOffloaded() async {
        let host = await Self.makeHost()
        let count = 300
        var rows = Self.rows(count: count, salt: "k2")
        let streamingIndex = count - 1, findIndex = count - 9, controlIndex = count - 13
        let body = String(repeating: "filler words that wrap ", count: 12)
        rows[streamingIndex] = Self.assistant("stream", text: "Streaming reply " + body, streaming: true, at: streamingIndex)
        rows[findIndex] = Self.assistant("find", text: "Find the needle in this reply. " + body, at: findIndex)
        rows[controlIndex] = Self.assistant("control", text: "Plain reply " + body, at: controlIndex)
        var highlight = TranscriptHighlight()
        highlight.query = "needle"
        highlight.rows = ["a-find"]
        host.coordinator.apply(highlight)

        let renderer = host.coordinator.renderer
        #expect(renderer.premeasureBodies(for: rows[streamingIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[findIndex]) == nil)
        #expect(renderer.premeasureBodies(for: rows[controlIndex]) != nil)

        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        await Self.idle(host)
        #if DEBUG
        let offloaded = Self.driver(host.coordinator).offloadedIds
        #expect(offloaded.contains("a-control"), "eligible neighbours are offloaded")
        #expect(!offloaded.contains("a-stream"))
        #expect(!offloaded.contains("a-find"))
        #endif
    }

    @Test func streamingUpdatesAndUnchangedHighlightDoNotStallThePrefetch() async {
        let host = await Self.makeHost()
        var rows = Self.rows(count: 1500, salt: "k4")
        rows.append(Self.assistant("live", text: "Streaming", streaming: true, at: rows.count))
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // updateUIView re-applies the (unchanged) highlight on every flush; the flushes must not cancel the worker.
        for step in 0..<60 {
            rows[rows.count - 1] = Self.assistant("live", text: "Streaming " + String(repeating: "token ", count: step + 1),
                                                  streaming: true, at: rows.count - 1)
            host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
            host.coordinator.apply(TranscriptHighlight())
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Self.idle(host)
        _ = await eventually(timeout: .seconds(30)) { host.coordinator.premeasureStats.adopted > 0 }
        await Self.drained(host)
        let stats = host.coordinator.premeasureStats
        print("\nTranscriptPremeasure UIKit streaming: premeasureStats \(stats)")
        #expect(stats.adopted > 0, "results were adopted while the last row streamed")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #if DEBUG
        #expect(!Self.driver(host.coordinator).offloadedIds.contains("a-live"))
        #endif
    }

    @Test func pagingOlderRowsAndTrimmingWhileJobsAreInFlightLeavesNothingInFlight() async {
        let host = await Self.makeHost()
        let rows = Self.rows(count: 3000, salt: "k3")
        host.coordinator.update(rows: rows, context: host.context, insets: (0, 0))
        // Catch jobs on the worker, then reshape the list under them.
        _ = await eventually(timeout: .seconds(10)) { Self.driver(host.coordinator).inFlightCount > 0 }
        let sawInFlight = Self.driver(host.coordinator).inFlightCount > 0
        let older = Self.rows(count: 100, salt: "k3old")
        host.coordinator.update(rows: older + rows, context: host.context, insets: (0, 0))
        host.coordinator.update(rows: Array((older + rows).dropFirst(150)), context: host.context, insets: (0, 0))
        await Self.idle(host)
        print("\nTranscriptPremeasure UIKit windowing: jobs were in flight at reshape \(sawInFlight); premeasureStats \(host.coordinator.premeasureStats)")
        #expect(sawInFlight, "the test reshaped the list while jobs were in flight")
        #expect(Self.driver(host.coordinator).inFlightCount == 0)
        #expect(Self.driver(host.coordinator).inFlight.isEmpty)
    }

    @Test func theRowWindowCoversTheVisibleRows() async {
        let host = await Self.makeHost()
        host.coordinator.update(rows: Self.rows(count: 400, salt: "k5"), context: host.context, insets: (0, 0))
        await Self.idle(host)
        let visible = try! #require(host.coordinator.visibleRows)
        let window = try! #require(host.coordinator.rowWindow(screens: 1, minimum: 200))
        #expect(window.range.contains(visible.lowerBound) && window.range.contains(visible.upperBound))
        #expect(visible.contains(window.center))
        #expect(window.range.count > visible.count, "the window reaches past the screen")
        #expect(visible.upperBound == 399, "a new list opens at the latest message")
    }
}
#endif
