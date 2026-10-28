import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import PincerKit

final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.lock(); done = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

/// A frame source the test drives by hand.
final class FakeBrowserSource: BrowserFrameSource {
    let ticket: BrowserPanelModel.Ticket
    private let continuation: Mutex<AsyncThrowingStream<BrowserStreamEvent, Error>.Continuation?> = Mutex(nil)
    private let stream: AsyncThrowingStream<BrowserStreamEvent, Error>
    private let flag = TerminationFlag()

    init(ticket: BrowserPanelModel.Ticket) {
        self.ticket = ticket
        var cont: AsyncThrowingStream<BrowserStreamEvent, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation.withLock { $0 = cont }
        let flag = self.flag
        cont.onTermination = { _ in flag.set() }
    }

    func frames() -> AsyncThrowingStream<BrowserStreamEvent, Error> { stream }
    var terminated: Bool { flag.value }
    func send(_ event: BrowserStreamEvent) { _ = continuation.withLock { $0?.yield(event) } }
    func fail(_ error: Error) { continuation.withLock { $0?.finish(throwing: error) } }
    func close(_ code: Int?) { send(.closed(code: code)); continuation.withLock { $0?.finish() } }

    static func frame(sequence: Int = 1, url: String? = "https://example.com/") -> BrowserFrame {
        let image = BrowserFixtures.jpeg(width: 4, height: 3)
        let cg = BrowserFrameDecoder.decode(image, maxPixelSize: 64)!
        return BrowserFrame(image: cg, pageURL: url.flatMap(URL.init(string:)), cssSize: CGSize(width: 800, height: 600), sequence: sequence)
    }
}

/// Records the model's gateway requests and the sources it opens.
final class BrowserModelHarness: Sendable {
    struct Call: Sendable { let method: String; let params: JSONValue }
    let calls = Mutex<[Call]>([])
    let sources = Mutex<[FakeBrowserSource]>([])
    let running = Mutex(true)
    let admin = Mutex(true)
    let failScreencast = Mutex(false)
    /// What `/act` throws, when set (nil: it succeeds).
    let actError = Mutex<(any Error)?>(nil)

    func paths(_ path: String) -> Int { calls.withLock { $0.filter { $0.params["path"]?.string == path }.count } }
    var latestSource: FakeBrowserSource? { sources.withLock { $0.last } }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls.withLock { $0.append(Call(method: method, params: params)) }
        switch params["path"]?.string {
        case "/tabs":
            let tabs = running.withLock { $0 } ? #"[{"targetId":"T1","title":"One","url":"https://one.test/"},{"targetId":"T2","title":"Two","url":"javascript:x"}]"# : "[]"
            return Fixtures.json(#"{"running":\#(running.withLock { $0 }),"tabs":\#(tabs),"canAutoResizeViewport":true}"#)
        case "/screencast":
            if failScreencast.withLock({ $0 }) { throw URLError(.cannotConnectToHost) }
            let target = params["body"]?["targetId"]?.string ?? "T1"
            return Fixtures.json(#"{"token":"tok","wsPath":"/browser/screencast?token=tok\#(calls.withLock { $0.count })","targetId":"\#(target)","url":"https://one.test/"}"#)
        case "/act":
            if let error = actError.withLock({ $0 }) { throw error }
            return .null
        default:
            return .null
        }
    }

    @MainActor func model(debounce: Duration = .milliseconds(5), retryDelay: Duration = .milliseconds(50)) -> BrowserPanelModel {
        BrowserPanelModel(
            request: { [self] method, params in try await self.request(method, params) },
            hasAdmin: { [self] in self.admin.withLock { $0 } },
            makeSource: { [self] ticket in
                let source = FakeBrowserSource(ticket: ticket)
                self.sources.withLock { $0.append(source) }
                return source
            },
            debounce: debounce, retryDelay: retryDelay)
    }
}

@MainActor
private func browserEventually(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + waitDeadline(.seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
struct BrowserPanelModelTests {
    private let size = CGSize(width: 900, height: 700)

    @Test func withoutAdminItNeedsFullManagementAndNeverAsks() async {
        let harness = BrowserModelHarness()
        harness.admin.withLock { $0 = false }
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { model.status == .needsFullManagement })
        await model.refreshTabs()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.status == .needsFullManagement)
        #expect(harness.calls.withLock { $0.isEmpty }, "no browser.request is sent without admin")
        #expect(harness.sources.withLock { $0.isEmpty })
        model.stop()
    }

    @Test func refreshTabsListsPagesAndDropsUnsafeURLs() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        await model.refreshTabs()
        #expect(model.tabs.map(\.id) == ["T1", "T2"])
        #expect(model.tabs[0].url == URL(string: "https://one.test/"))
        #expect(model.tabs[1].url == nil, "a non-http page URL isn't kept")
        let call = harness.calls.withLock { $0.first }
        #expect(call?.method == "browser.request")
        #expect(call?.params["method"]?.string == "GET")
    }

    @Test func notRunningWhenTheBrowserIsStopped() async {
        let harness = BrowserModelHarness()
        harness.running.withLock { $0 = false }
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { model.status == .notRunning })
        #expect(harness.paths("/screencast") == 0)
        model.stop()
    }

    @Test func goesLiveAfterAFrame() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        #expect(model.status != .live, "not live before the first frame")
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await browserEventually { model.status == .live })
        #expect(model.frame != nil)
        harness.latestSource?.send(.meta(url: URL(string: "https://two.test/"), title: "Two"))
        #expect(await browserEventually { model.pageTitle == "Two" })
        #expect(model.pageURL == URL(string: "https://two.test/"))
        model.stop()
    }

    @Test func requestsAtMostTheCappedSize() async throws {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: CGSize(width: 5000, height: 4000))
        #expect(await browserEventually { harness.latestSource != nil })
        let ticket = try #require(harness.latestSource).ticket
        #expect(ticket.maxWidth <= 1600 && ticket.maxHeight <= 1200)
        model.stop()
    }

    @Test func aDroppedStreamReconnectsInsteadOfStayingDead() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        harness.latestSource?.send(.frame(FakeBrowserSource.frame()))
        #expect(await browserEventually { model.status == .live })
        harness.latestSource?.fail(URLError(.networkConnectionLost))
        #expect(await browserEventually { model.status == .reconnecting })
        #expect(await browserEventually { harness.sources.withLock { $0.count } >= 2 }, "asks for a new screencast")
        harness.latestSource?.send(.frame(FakeBrowserSource.frame(sequence: 2)))
        #expect(await browserEventually { model.status == .live })
        model.stop()
    }

    @Test func aFailedScreencastRequestRetriesAfterTheBackoff() async {
        let harness = BrowserModelHarness()
        harness.failScreencast.withLock { $0 = true }
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.paths("/screencast") >= 1 })
        harness.failScreencast.withLock { $0 = false }
        #expect(await browserEventually { harness.latestSource != nil }, "retries once the Gateway answers again")
        model.stop()
    }

    @Test func closeCode4004RefreshesTheTabs() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        let before = harness.paths("/tabs")
        harness.latestSource?.close(4004)
        #expect(await browserEventually { harness.paths("/tabs") > before })
        model.stop()
    }

    @Test func closeCode4003ShowsNavigationBlocked() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        harness.latestSource?.close(4003)
        #expect(await browserEventually { model.status == .navigationBlocked })
        model.stop()
    }

    @Test func gatewayReconnectRequestsANewScreencastWhileVisible() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        let before = harness.paths("/screencast")
        model.handleReconnect()
        #expect(await browserEventually { harness.paths("/screencast") > before })
        model.stop()
    }

    @Test func reconnectWhileHiddenDoesNothing() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.handleReconnect()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.paths("/screencast") == 0)
        #expect(harness.sources.withLock { $0.isEmpty })
    }

    @Test func hidingStopsTheStream() async throws {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size)
        #expect(await browserEventually { harness.latestSource != nil })
        let source = try #require(harness.latestSource)
        model.setVisible(false, pixelSize: size)
        #expect(await browserEventually { source.terminated })
        #expect(model.status == .idle)
    }

    @Test func streamSurvivesUntilTheLastViewerLeaves() async throws {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewer: "a")
        model.setVisible(true, pixelSize: size, viewer: "b")
        #expect(await browserEventually { harness.latestSource != nil })
        let source = try #require(harness.latestSource)
        model.setVisible(false, pixelSize: size, viewer: "a")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!source.terminated, "one window closing leaves the other streaming")
        #expect(harness.paths("/screencast") == 1)
        model.setVisible(false, pixelSize: size, viewer: "b")
        #expect(await browserEventually { source.terminated })
        #expect(model.status == .idle)
    }

    @Test func secondViewerAtTheSameSizeDoesNotRestart() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: size, viewer: "a")
        #expect(await browserEventually { harness.latestSource != nil })
        model.setVisible(true, pixelSize: size, viewer: "b")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.paths("/screencast") == 1)
        model.stop()
    }

    @Test func streamsAtTheLargestViewerSize() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        model.setVisible(true, pixelSize: CGSize(width: 600, height: 400), viewer: "small")
        model.setVisible(true, pixelSize: CGSize(width: 1000, height: 800), viewer: "big")
        #expect(await browserEventually { harness.paths("/screencast") >= 1 })
        let body = harness.calls.withLock { $0.last { $0.params["path"]?.string == "/screencast" } }?.params["body"]
        #expect(body?.object?["maxWidth"]?.int == 1000)
        #expect(body?.object?["maxHeight"]?.int == 800)
        model.stop()
    }

    @Test func selectingARefSelectsOrAddsATab() async {
        let harness = BrowserModelHarness()
        let model = harness.model()
        await model.refreshTabs()
        model.select(BrowserTabRef(targetId: "T2", profile: nil, target: nil, node: nil, url: nil, title: nil))
        #expect(model.selectedTargetId == "T2")
        model.select(BrowserTabRef(targetId: "T9", profile: "p", target: "host", node: nil,
                                   url: URL(string: "https://nine.test/"), title: "Nine"))
        #expect(model.selectedTargetId == "T9")
        #expect(model.tabs.contains { $0.id == "T9" && $0.title == "Nine" }, "a placeholder is added for an unknown page")
    }
}

struct BrowserFrameDecoderTests {
    @Test func honoursThePixelCap() throws {
        let jpeg = BrowserFixtures.jpeg(width: 400, height: 300)
        let small = try #require(BrowserFrameDecoder.decode(jpeg, maxPixelSize: 100))
        #expect(max(small.width, small.height) <= 100)
        let full = try #require(BrowserFrameDecoder.decode(jpeg, maxPixelSize: 4000))
        #expect(full.width == 400 && full.height == 300, "never upscales")
    }

    @Test func garbageDoesNotDecode() {
        #expect(BrowserFrameDecoder.decode(Data([1, 2, 3, 4]), maxPixelSize: 100) == nil)
        #expect(BrowserFrameDecoder.decode(Data(), maxPixelSize: 100) == nil)
    }

    @Test func theCapNeverExceeds2048() throws {
        let jpeg = BrowserFixtures.jpeg(width: 2600, height: 100)
        let image = try #require(BrowserFrameDecoder.decode(jpeg, maxPixelSize: 9000))
        #expect(max(image.width, image.height) <= 2048)
    }

    @Test func pumpIsLatestWinsAndDropsBadFrames() async {
        let pump = BrowserFramePump(maxPixelSize: 64)
        let sizes = [(40, 30), (41, 30), (42, 30), (43, 30), (44, 30), (45, 30)]
        pump.push(Data([0, 0, 0]))
        pump.push(BrowserFixtures.message(header: "{bad", jpeg: BrowserFixtures.jpeg(width: 9, height: 9)))
        for size in sizes { pump.push(BrowserFixtures.message(header: BrowserFixtures.header, jpeg: BrowserFixtures.jpeg(width: size.0, height: size.1))) }
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); pump.finish() }
        var widths: [Int] = []
        for await frame in pump.frames {
            widths.append(frame.image.width)
            if frame.image.width == 45 { break }
        }
        watchdog.cancel()
        pump.finish()
        #expect(widths.last == 45, "the newest frame wins (got \(widths))")
        #expect(widths.count <= sizes.count)
        #expect(widths == widths.sorted(), "a stale frame is never delivered after a newer one")
        #expect(!widths.contains(9), "a frame with a bad header is dropped")
    }
}
