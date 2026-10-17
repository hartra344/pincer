import CoreGraphics
import Foundation
@testable import PincerKit

/// A source that plays a fixed script and then stays open, like a socket on a page that isn't repainting,
/// unless the script ends in a close.
private struct ScriptedBrowserSource: BrowserFrameSource {
    let events: [BrowserStreamEvent]
    func frames() -> AsyncThrowingStream<BrowserStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if case .closed = events.last { continuation.finish() }
        }
    }
}

private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var tickets = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; tickets += 1; return tickets }
    var value: Int { lock.lock(); defer { lock.unlock() }; return tickets }
}

/// #1027: a static page's stream stays "Reconnecting…" forever, and a permanent failure is retried forever.
@MainActor
func runBrowserStreamResilienceChecks() async {
    let tabs = json(#"{"running":true,"tabs":[{"targetId":"T1","title":"One","url":"https://one.test/"}],"canAutoResizeViewport":true}"#)
    func model(counter: StreamCounter, source: @escaping @Sendable () -> any BrowserFrameSource) -> BrowserPanelModel {
        BrowserPanelModel(
            request: { _, params in
                if params["path"]?.string == "/tabs" { return tabs }
                _ = counter.bump()
                return json(#"{"token":"t","wsPath":"/browser/screencast?token=t","targetId":"T1","url":"https://one.test/"}"#)
            },
            makeSource: { _ in source() }, debounce: .milliseconds(5), retryDelay: .milliseconds(5))
    }
    let pixels = CGSize(width: 900, height: 700)

    // Upstream sends `ready` and then frames only on repaint: ready alone must read as connected.
    let ready = StreamCounter()
    let staticPage = model(counter: ready) {
        ScriptedBrowserSource(events: [.meta(url: URL(string: "https://one.test/"), title: "One")])
    }
    staticPage.setVisible(true, pixelSize: pixels)
    let live = await waitFor("static page goes live on ready", timeout: 5) { staticPage.status == .live }
    check(live, "stream resilience: a ready message with no frame is live, not Reconnecting… (\(staticPage.status))")
    staticPage.stop()

    // A socket the Gateway closes 4005 (unsupported) is final.
    let unsupported = StreamCounter()
    let noStream = model(counter: unsupported) { ScriptedBrowserSource(events: [.closed(code: 4005)]) }
    noStream.setVisible(true, pixelSize: pixels)
    let terminal = await waitFor("4005 is terminal", timeout: 5) { noStream.status == .unstreamable }
    try? await Task.sleep(for: .milliseconds(200))
    check(terminal && unsupported.value == 1, "stream resilience: close 4005 shows an error and doesn't retry (\(unsupported.value) tickets)")
    noStream.stop()

    // A socket that never connects ends in a terminal error after a bounded number of tries.
    let never = StreamCounter()
    let dead = model(counter: never) { ScriptedBrowserSource(events: [.closed(code: 1006)]) }
    dead.setVisible(true, pixelSize: pixels)
    let gaveUp = await waitFor("bounded retries", timeout: 8) { if case .failed = dead.status { true } else { false } }
    let seen = never.value
    try? await Task.sleep(for: .milliseconds(300))
    check(gaveUp && never.value == seen && seen <= 8, "stream resilience: a socket that never connects stops after \(seen) tries")
    dead.stop()

    // Only a regular-width host resizes the agent's page; a compact (phone) panel just views it.
    for compact in [true, false] {
        let acts = StreamCounter()
        let panel = BrowserPanelModel(
            request: { _, params in
                switch params["path"]?.string {
                case "/tabs": return tabs
                case "/act": _ = acts.bump(); return .null
                default: return json(#"{"token":"t","wsPath":"/browser/screencast?token=t","targetId":"T1","url":"https://one.test/"}"#)
                }
            },
            makeSource: { _ in ScriptedBrowserSource(events: [.meta(url: URL(string: "https://one.test/"), title: "One")]) },
            debounce: .milliseconds(5), retryDelay: .milliseconds(5))
        panel.setVisible(true, pixelSize: pixels, viewport: CGSize(width: 390, height: 750), compact: compact)
        _ = await waitFor("viewport sync (compact \(compact))", timeout: 3) { acts.value > 0 }
        try? await Task.sleep(for: .milliseconds(500))
        check(compact ? acts.value == 0 : acts.value == 1,
              "stream resilience: a \(compact ? "compact" : "regular-width") panel sent \(acts.value) resize request(s)")
        panel.stop()
    }
}
