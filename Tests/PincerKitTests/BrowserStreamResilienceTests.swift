import CoreGraphics
import Foundation
import Testing
@testable import PincerKit

/// #1027: the panel sat on "Reconnecting…" forever. Upstream sends `ready`/`meta` text messages and
/// frames only on repaint, so a static page never produced a frame to flip the status; and permanent
/// failures were retried without end.
@MainActor
struct BrowserStreamResilienceTests {
    private let size = CGSize(width: 900, height: 700)

    @Test func aReadyMessageAloneMakesTheStreamLive() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.meta(url: URL(string: "https://one.test/"), title: "One"))
        #expect(await eventually { model.status == .live }, "ready means connected, even before a frame (static page)")
        model.stop()
    }

    @Test func aReconnectToAStaticPageGoesLiveWithoutANewFrame() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await eventually { model.status == .live })
        harness.latestSource?.close(1006)
        #expect(await eventually { model.status == .reconnecting })
        #expect(await eventually { harness.sources.withLock { $0.count } == 2 })
        harness.latestSource?.send(.meta(url: nil, title: "One"))
        #expect(await eventually { model.status == .live }, "the shown frame is current again once the socket is ready")
        model.stop()
    }

    @Test func unsupportedStreamingIsTerminal() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.close(4005)
        #expect(await eventually { if case .failed = model.status { true } else { false } })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(harness.sources.withLock { $0.count } == 1, "no retry after 4005")
        #expect(harness.paths("/screencast") == 1)
        model.stop()
    }

    @Test func aSocketThatNeverConnectsStopsRetrying() async {
        let harness = BrowserModelHarness()
        let model = harness.model(retryDelay: .milliseconds(5))
        model.setVisible(true, pixelSize: size)
        var seen = 0
        let ended = await eventually(timeout: .seconds(8)) {
            let sources = harness.sources.withLock { $0 }
            while seen < sources.count { sources[seen].close(1006); seen += 1 }
            if case .failed = model.status { return true }
            return false
        }
        #expect(ended, "a permanent connect failure ends in a terminal error")
        let count = harness.paths("/screencast")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(harness.paths("/screencast") == count, "and stops asking for tickets")
        #expect(count <= 8)
        model.stop()
    }

    @Test func aPermanentScreencastErrorStopsRetrying() async {
        let harness = BrowserModelHarness()
        harness.failScreencast.withLock { $0 = true }
        let model = harness.model(retryDelay: .milliseconds(5))
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { if case .failed = model.status { true } else { false } })
        try? await Task.sleep(for: .milliseconds(600))
        let first = harness.paths("/screencast")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(harness.paths("/screencast") == first, "bounded: it gives up")
        #expect(first <= 8)
        model.stop()
    }
}
