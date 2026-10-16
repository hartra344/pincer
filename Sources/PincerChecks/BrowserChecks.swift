import CoreGraphics
import Foundation
import ImageIO
@testable import PincerKit
import UniformTypeIdentifiers

// The live browser panel (#974): the screencast wire parser, browser tab references, the demo's
// browser tool cards and page frames, the real socket against the mock Gateway, and a decode perf smoke.

private func browserJPEG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for band in 0..<8 {
        context.setFillColor(CGColor(red: Double(band) / 8, green: 0.5, blue: 1 - Double(band) / 8, alpha: 1))
        context.fill(CGRect(x: 0, y: band * height / 8, width: width, height: height / 8 + 1))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func browserMessage(header: String, jpeg: Data) -> Data {
    let head = Data(header.utf8)
    var length = UInt32(head.count).bigEndian
    var out = Data(bytes: &length, count: 4)
    out.append(head)
    out.append(jpeg)
    return out
}

private let browserHeader = #"{"url":"https://example.com/a","cssWidth":1280,"cssHeight":800,"scrollX":0,"scrollY":0,"ts":1}"#

private func rejects(_ data: Data) -> Bool {
    (try? BrowserScreencastWire.parse(data)) == nil
}

@MainActor
func runBrowserOfflineChecks() {
    let jpeg = browserJPEG(width: 32, height: 20)
    let ok = try? BrowserScreencastWire.parse(browserMessage(header: browserHeader, jpeg: jpeg))
    check(ok?.jpeg == jpeg && ok?.header.url == "https://example.com/a" && ok?.header.cssWidth == 1280,
          "browser wire: a valid frame parses to its header and JPEG")
    check((try? BrowserScreencastWire.parse(browserMessage(header: "{}", jpeg: Data([1])))) != nil,
          "browser wire: every header field is optional")
    check(rejects(Data()) && rejects(Data([0, 0])), "browser wire: empty and short input is rejected")
    var cut = browserMessage(header: browserHeader, jpeg: Data())
    cut.removeLast(8)
    check(rejects(cut), "browser wire: a header length past the data is rejected")
    var absurd = UInt32.max.bigEndian
    check(rejects(Data(bytes: &absurd, count: 4) + Data(count: 32)), "browser wire: an absurd header length is rejected")
    let bigHeader = #"{"url":""# + String(repeating: "a", count: 64 * 1024 + 1) + #""}"#
    check(rejects(browserMessage(header: bigHeader, jpeg: Data([1]))), "browser wire: a header over 64 KiB is rejected")
    check(rejects(browserMessage(header: "{}", jpeg: Data(count: 8 * 1024 * 1024 + 1))), "browser wire: a message over 8 MiB is rejected")
    check(rejects(browserMessage(header: "{nope", jpeg: Data([1]))), "browser wire: invalid header JSON is rejected")
    check(BrowserScreencastWire.parseControl(#"{"type":"ready","targetId":"t","url":"https://a.test","title":"A"}"#)
          == .ready(targetId: "t", url: "https://a.test", title: "A"), "browser wire: a ready message parses")
    check(BrowserScreencastWire.parseControl("garbage") == nil && BrowserScreencastWire.parseControl(#"{"type":"?"}"#) == nil,
          "browser wire: unknown control text is ignored")

    let hostile = ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "chrome://settings", "about:blank"]
    check(hostile.allSatisfy { BrowserTabRef.parse(json(#"{"browserTab":{"targetId":"T","url":"\#($0)"}}"#))?.url == nil },
          "browser tab: non-http URLs are dropped")
    let ref = BrowserTabRef.parse(json(#"{"browserTab":{"targetId":"T","profile":"p","target":"host","url":"https://docs.openclaw.ai/x","title":"Docs"}}"#))
    check(ref?.host == "docs.openclaw.ai" && ref?.profile == "p" && ref?.target == "host", "browser tab: an https page keeps its host and route")
    check(BrowserTabRef.parse(json(#"{"browserTab":{"title":"x"}}"#)) == nil && BrowserTabRef.parse(nil) == nil,
          "browser tab: no targetId means no reference")

    let gateway = URL(string: "ws://127.0.0.1:18789")!
    check(BrowserScreencastClient.resolveURL(wsPath: "/browser/screencast?token=t", gateway: gateway)?.absoluteString
          == "ws://127.0.0.1:18789/browser/screencast?token=t", "browser socket: wsPath resolves against the Gateway URL")
    check(BrowserScreencastClient.resolveURL(wsPath: "ws://evil.example/x", gateway: gateway) == nil,
          "browser socket: a plain-ws or public absolute URL is refused")
    check(BrowserScreencastClient.resolveURL(wsPath: "file:///etc/passwd", gateway: gateway) == nil, "browser socket: a non-ws scheme is refused")

    let big = browserJPEG(width: 600, height: 300)
    let image = BrowserFrameDecoder.decode(big, maxPixelSize: 100)
    check(image.map { max($0.width, $0.height) <= 100 } == true, "browser decode: the pixel cap is honoured")
    check(BrowserFrameDecoder.decode(Data([1, 2, 3]), maxPixelSize: 100) == nil, "browser decode: garbage doesn't decode")
}

/// Waits for the pump to deliver `count` frames, or `timeout` seconds.
private func collectFrames(_ pump: BrowserFramePump, until done: @escaping @Sendable (BrowserFrame) -> Bool, timeout: Double) async -> [BrowserFrame] {
    await withTaskGroup(of: [BrowserFrame].self) { group in
        group.addTask {
            var frames: [BrowserFrame] = []
            for await frame in pump.frames {
                frames.append(frame)
                if done(frame) { break }
            }
            return frames
        }
        group.addTask { try? await Task.sleep(for: .seconds(timeout)); return [] }
        let first = await group.next() ?? []
        group.cancelAll()
        return first
    }
}

@MainActor
func runDemoBrowserChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("browser Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "browser demo connects")
        return
    }
    let model = gateway.browserPanel
    await model.refreshTabs()
    check(model.tabs.count == 2 && model.tabs.allSatisfy { !$0.id.isEmpty }, "demo: /tabs lists 2 pages (\(model.tabs.count))")
    model.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
    let live = await waitFor("demo browser frame", timeout: 20) { model.status == .live && model.frame != nil }
    check(live, "demo: the panel goes live with a frame (\(model.status))")
    check(model.frame.map { $0.image.width > 0 && $0.cssSize.width > 0 } == true, "demo: the frame has pixels and a page size")
    model.setVisible(false, pixelSize: .zero)
    check(model.status == .idle, "demo: hiding the panel stops the stream")
    model.stop()

    let source = BrowserDemoFrameSource(targetId: BrowserDemoPages.docs.targetId, framesPerSecond: 10)
    var sawFrame = false
    do {
        for try await event in source.frames() {
            if case .frame = event { sawFrame = true; break }
        }
    } catch {}
    check(sawFrame, "demo: the frame source yields a frame")
}

@MainActor
func runLiveBrowserChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock browser", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("mock for the browser panel", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }) else {
        check(false, "browser: mock connected")
        return
    }
    defer { gateway.stop() }
    let connection = gateway.connection
    let tabs = try? await connection.request("browser.request", ["method": "GET", "path": "/tabs"])
    check(tabs?["running"]?.bool == true && (tabs?["tabs"]?.array?.count ?? 0) >= 2, "mock: /tabs lists the pages")
    let targetId = tabs?["tabs"]?.array?.first?["targetId"]?.string ?? ""
    let ticket = try? await connection.request("browser.request", ["method": "POST", "path": "/screencast",
        "body": ["targetId": .string(targetId), "maxWidth": 800, "maxHeight": 600]])
    guard let wsPath = ticket?["wsPath"]?.string, let socketURL = URL(string: url).flatMap({ BrowserScreencastClient.resolveURL(wsPath: wsPath, gateway: $0) }) else {
        check(false, "mock: /screencast returns a wsPath that resolves")
        return
    }
    var frame: BrowserFrame?
    var sawMeta = false
    do {
        for try await event in BrowserScreencastClient(url: socketURL, fingerprint: nil, maxPixelSize: 800).frames() {
            switch event {
            case .frame(let value): frame = value
            case .meta: sawMeta = true
            case .closed: break
            }
            if frame != nil { break }
        }
    } catch {}
    check(frame != nil && sawMeta, "mock: the real socket delivers a ready message and a decoded frame")
    check(frame.map { max($0.image.width, $0.image.height) <= 800 && $0.pageURL?.scheme == "https" } == true,
          "mock: the frame honours the pixel cap and carries an http(s) page URL")

    for hook in ["bad-header-length", "oversized-header"] {
        let bad = try? await connection.request("browser.request", ["method": "POST", "path": "/screencast", "body": ["targetId": .string(hook)]])
        guard let path = bad?["wsPath"]?.string, let badURL = URL(string: url).flatMap({ BrowserScreencastClient.resolveURL(wsPath: path, gateway: $0) }) else {
            check(false, "mock: \(hook) hook mints a socket")
            continue
        }
        var gotFrame = false
        let stream = BrowserScreencastClient(url: badURL, fingerprint: nil, maxPixelSize: 800).frames()
        let reader = Task { do { for try await event in stream { if case .frame = event { gotFrame = true } } } catch {} }
        try? await Task.sleep(for: .seconds(1.5))
        reader.cancel()
        check(!gotFrame, "mock: a malformed frame (\(hook)) is dropped without crashing")
    }

    let model = gateway.browserPanel
    model.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
    let live = await waitFor("mock browser panel live", timeout: 20) { model.status == .live && model.frame != nil }
    check(live, "mock: the panel goes live end to end (\(model.status))")
    model.stop()

    let standard = GatewayProfile(name: "Mock standard", url: url, authMode: .token)
    standard.secret = token
    let limited = GatewayStore(profile: standard)
    limited.start()
    limited.reconnectIfNeeded()
    if await waitFor("standard mock connection", timeout: 25, { limited.state.isConnected && limited.bootstrapped }) {
        limited.browserPanel.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
        let asked = await waitFor("needs Full Management", timeout: 10, { limited.browserPanel.status == .needsFullManagement })
        check(asked, "mock: without Full Management the panel asks for it")
        limited.browserPanel.stop()
    }
    limited.stop()
}

/// 300 frames through the latest-wins pump. The main thread only pays for `push`.
@MainActor
func checkBrowserFrameDecodePerfSmoke() async {
    let jpeg = browserJPEG(width: 1280, height: 800)
    let message = browserMessage(header: browserHeader, jpeg: jpeg)
    let pump = BrowserFramePump(maxPixelSize: 1600)
    let clock = ContinuousClock()
    var pushTime = Duration.zero
    var delivered = 0
    var iterator = pump.frames.makeAsyncIterator()
    let watchdog = Task { try? await Task.sleep(for: .seconds(60)); pump.finish() }
    defer { watchdog.cancel() }
    let start = clock.now
    for index in 0..<300 {
        pushTime += clock.measure { pump.push(message) }
        guard await iterator.next() != nil else { check(false, "browser perf: frame \(index) decoded"); break }
        delivered += 1
    }
    let total = clock.now - start
    pump.finish()
    let ms = { (d: Duration) in d.formatted(.units(allowed: [.milliseconds])) }
    print("  · perf smoke: 300 × 1280×800 JPEG frames decoded in \(ms(total)); main-thread push cost \(ms(pushTime))")
    check(delivered == 300, "browser perf: every frame sent one at a time is decoded (\(delivered))")
    check(pushTime < .milliseconds(100), "browser perf: handing 300 frames over costs the main thread under 100 ms")
    check(total < .seconds(30), "browser perf: 300 frames decode under the absolute ceiling")

    let burst = BrowserFramePump(maxPixelSize: 1600)
    let last = browserMessage(header: browserHeader.replacingOccurrences(of: "/a\"", with: "/last\""), jpeg: jpeg)
    for _ in 0..<299 { burst.push(message) }
    burst.push(last)
    let seen = await collectFrames(burst, until: { $0.pageURL?.path == "/last" }, timeout: 20)
    burst.finish()
    check(seen.last?.pageURL?.path == "/last", "browser perf: the burst's final frame is decoded and delivered (\(seen.count) delivered)")
    check(!seen.isEmpty && (seen.last?.sequence ?? .max) < 300, "browser perf: a burst of 300 is thinned by latest-wins (\(seen.last?.sequence ?? -1) decoded)")
}
