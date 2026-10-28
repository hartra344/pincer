import CoreGraphics
import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
import WebKit
#endif

/// ImageIO can't decode SVG, so agent-drawn SVGs (charts, illustrations) are rasterized here.
/// macOS draws them with `NSImage` off the main thread; iOS has no public SVG decoder, so it renders
/// the SVG as an `<img>` in a script-less web view (main-actor only, and it must be in a window),
/// where SVG can't run scripts or load external resources.
public struct SVGRasterizer: SVGRasterizing {
    public init() {}

    /// Registers this as the app's SVG rasterizer; call once at launch.
    @MainActor public static func install() { SVGRasterization.provider = SVGRasterizer() }

    public static func isSVG(_ data: Data) -> Bool { SVGSource.isSVG(data) }

    public static func rasterize(_ data: Data) async -> CGImage? {
        let bounds = CGSize(width: SVGSource.thumbnailPixelSize, height: SVGSource.thumbnailPixelSize)
        return await self.rasterize(data, fitting: bounds)
    }

    /// Renders the SVG as large as fits in `bounds` (in pixels), keeping its aspect ratio.
    public static func rasterize(_ data: Data, fitting bounds: CGSize) async -> CGImage? {
        await self.rasterize(data, fitting: bounds, webLaunchTimeout: .seconds(180), webStepTimeout: .seconds(45))
    }

    /// On iOS, `webLaunchTimeout` caps the wait for the web content process to commit the page. A cold
    /// launch on a loaded CI simulator took 20 to over 90 s, and WebKit reports a failed launch itself.
    /// After the commit, `webStepTimeout` caps each remaining step (finishing the load, the snapshot),
    /// which only a hang exceeds.
    static func rasterize(
        _ data: Data, fitting bounds: CGSize, webLaunchTimeout: Duration, webStepTimeout: Duration) async -> CGImage?
    {
        guard let intrinsic = SVGSource.intrinsicSize(data), bounds.width >= 1, bounds.height >= 1 else { return nil }
        let pixels = SVGSource.pixelSize(for: intrinsic, fitting: bounds)
        #if os(macOS)
        return await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: data) else { return nil }
            var rect = CGRect(origin: .zero, size: pixels)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return Self.redraw(cgImage, size: pixels)
        }.value
        #else
        return await WebSnapshotter.snapshot(
            svg: data, size: intrinsic, pixels: pixels, launchTimeout: webLaunchTimeout, stepTimeout: webStepTimeout)
        #endif
    }

    public func rasterize(_ data: Data, fitting bounds: CGSize) async -> CGImage? {
        await Self.rasterize(data, fitting: bounds)
    }

    /// Draws into a plain 8-bit sRGB bitmap: `NSImage` hands back a float, screen-profile image.
    static func redraw(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}

#if os(iOS)
@MainActor
private final class WebSnapshotter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    /// When the current step's watchdog gives up; the commit moves it from the launch budget to the step budget.
    private var deadline = ContinuousClock.now
    private var stepTimeout = Duration.zero
    private var image: CGImage?
    /// WebKit never answered a step, or its web content process died. A loaded simulator once left
    /// a render pending for over nine minutes; now the step gives up and a fresh web view tries again.
    private var stalled = false
    /// Shared so every render after the first reuses a warm web content process; a fresh data store per
    /// render cold-started a new process each time.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    static func snapshot(
        svg: Data, size: CGSize, pixels: CGSize, launchTimeout: Duration, stepTimeout: Duration) async -> CGImage?
    {
        for _ in 0..<2 {
            let (image, stalled) = await self.render(
                svg: svg, size: size, pixels: pixels, launchTimeout: launchTimeout, stepTimeout: stepTimeout)
            if image != nil || !stalled || Task.isCancelled { return image }
        }
        return nil
    }

    private static func render(
        svg: Data, size: CGSize, pixels: CGSize, launchTimeout: Duration, stepTimeout: Duration) async
        -> (CGImage?, stalled: Bool)
    {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        // Web views only paint while in a window; park it off-screen for the snapshot.
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        view.frame.origin = CGPoint(x: -size.width - 10_000, y: 0)
        window?.addSubview(view)
        defer { view.removeFromSuperview() }

        let delegate = WebSnapshotter()
        delegate.stepTimeout = stepTimeout
        view.navigationDelegate = delegate
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(Int(size.width)), initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        img{display:block;width:\(size.width)px;height:\(size.height)px}</style></head>
        <body><img src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
        """
        // A row scrolled away cancels its render: stop WebKit instead of finishing the load and snapshot.
        let loaded = await delegate.step(timeout: launchTimeout, stop: { view.stopLoading() }) {
            view.loadHTMLString(html, baseURL: nil)
        }
        guard loaded, !Task.isCancelled else { return (nil, delegate.stalled) }
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(pixels.width / view.traitCollection.displayScale))
        snapshotConfiguration.afterScreenUpdates = true
        _ = await delegate.step(timeout: stepTimeout, stop: {}) {
            view.takeSnapshot(with: snapshotConfiguration) { snapshot, _ in
                delegate.image = snapshot?.cgImage
                delegate.finish(true)
            }
        }
        guard let image = delegate.image, !Task.isCancelled else { return (nil, delegate.stalled) }
        return (SVGRasterizer.redraw(image, size: pixels), false)
    }

    /// Runs `start` and waits for `finish`, giving up (and calling `stop`) on cancellation or after `timeout`.
    private func step(timeout: Duration, stop: @escaping @MainActor @Sendable () -> Void, _ start: () -> Void) async -> Bool {
        self.deadline = .now + timeout
        let watchdog = Task { [weak self] in
            while let deadline = self?.deadline, ContinuousClock.now < deadline {
                // Wakes at least every second: the commit can pull the deadline in.
                try? await Task.sleep(until: min(deadline, .now + .seconds(1)))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self, self.continuation != nil else { return }
            self.stalled = true
            stop()
            self.finish(false)
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in
                stop()
                self.finish(false)
            }
        }
    }

    fileprivate func finish(_ loaded: Bool) {
        self.continuation?.resume(returning: loaded)
        self.continuation = nil
    }

    /// The web content process is up and has the page: from here on, only a hang is slow.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        self.deadline = .now + self.stepTimeout
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { self.finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.finish(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.stalled = true
        self.finish(false)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    {
        decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
#endif
