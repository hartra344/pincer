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
        #expect(await eventually { model.status == .unstreamable })
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

    @Test func theViewportIsMatchedToThePanelOnce() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 740, height: 1000))
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 1 })
        let body = harness.calls.withLock { $0.first { $0.params["path"]?.string == "/act" }?.params["body"] }
        #expect(body?["kind"]?.string == "resize" && body?["width"]?.int == 740 && body?["height"]?.int == 1000)
        harness.latestSource?.send(.frame(FakeBrowserSource.frame(sequence: 2)))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(harness.paths("/act") == 1, "the same size is not requested again")
        model.stop()
    }

    @Test func aFrameDimsOnlyWhileStale() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        #expect(model.frameIsStale)
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.meta(url: nil, title: nil))
        #expect(await eventually { !model.frameIsStale })
        model.stop()
    }

    @Test func resizeTargetIsClamped() {
        #expect(BrowserPanelModel.resizeTarget(for: CGSize(width: 10, height: 99999)) == (100, 8192))
        #expect(BrowserPanelModel.resizeTarget(for: CGSize(width: 740.4, height: 1000.6)) == (740, 1001))
    }

    @Test func aCompactPanelNeverResizesTheAgentsBrowser() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 390, height: 750), compact: true)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await eventually { model.status == .live })
        try? await Task.sleep(for: .milliseconds(700))
        #expect(harness.paths("/act") == 0, "a phone only views: it never reflows the agent's page")
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 390, height: 750), compact: false)
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 1 }, "a regular-width host does")
        model.stop()
    }

    @Test func aGatewayRefusalSuppressesOnlyTheSameSize() async {
        let harness = BrowserModelHarness()
        harness.actError.withLock { $0 = GatewayError.rpc(code: "INVALID_REQUEST", message: "can't resize", details: nil) }
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 740, height: 1000))
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 1 })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame(sequence: 2)))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(harness.paths("/act") == 1, "the refused size isn't asked again")
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 700, height: 900))
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 2 }, "a different size is a new question")
        model.stop()
    }

    @Test func aTransientFailureIsNotARefusal() async {
        let harness = BrowserModelHarness()
        harness.actError.withLock { $0 = GatewayError.timeout("the resize") }
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewport: CGSize(width: 740, height: 1000))
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 1 })
        harness.actError.withLock { $0 = nil }
        harness.latestSource?.send(.frame(FakeBrowserSource.frame(sequence: 2)))
        #expect(await eventually(timeout: .seconds(3)) { harness.paths("/act") == 2 }, "a timeout doesn't switch resizing off")
        model.stop()
    }

    @Test func retriesBackOffOverAboutAMinute() async {
        #expect(BrowserPanelModel.retrySteps.map { $0 * 2 } == [2, 4, 8, 16, 30])
        #expect(BrowserPanelModel.retrySteps.map { $0 * 2 }.reduce(0, +) == 60)
        let harness = BrowserModelHarness()
        // A long delay keeps the model parked in .reconnecting while a starved main actor looks: with a
        // short one the retry restarts the stream (.loading) before the poll gets a turn.
        let model = harness.model(retryDelay: .seconds(60))
        model.setVisible(true, pixelSize: size)
        #expect(await eventually { harness.latestSource != nil })
        harness.latestSource?.close(1006)
        #expect(await eventually { model.status == .reconnecting && model.retryAttempt == 1 }, "the pill can say which try this is")
        model.stop()
    }
}
