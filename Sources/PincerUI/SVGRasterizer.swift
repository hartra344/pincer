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
    fileprivate static let svgRenderDeadline: Duration = .seconds(30)

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
        guard let image = await WebSnapshotter.snapshot(svg: data, size: intrinsic, pixels: pixels) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.redraw(image, size: pixels)
        }.value
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
    private enum Phase: String {
        case navigation
        case snapshot
    }

    private let view: WKWebView
    private let snapshotConfiguration: WKSnapshotConfiguration
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var lifetime: SVGRasterizationLifetime?
    private var renderedImage: CGImage?
    private var phase = Phase.navigation

    private init(view: WKWebView, snapshotConfiguration: WKSnapshotConfiguration) {
        self.view = view
        self.snapshotConfiguration = snapshotConfiguration
    }

    static func snapshot(svg: Data, size: CGSize, pixels: CGSize) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let html = await Task.detached(priority: .userInitiated) {
            """
            <!doctype html><html><head><meta name="viewport" content="width=\(Int(size.width)), initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
            img{display:block;width:\(size.width)px;height:\(size.height)px}</style></head>
            <body><img src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
            """
        }.value
        guard !Task.isCancelled else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(pixels.width / view.traitCollection.displayScale))
        snapshotConfiguration.afterScreenUpdates = true

        let operation = WebSnapshotter(view: view, snapshotConfiguration: snapshotConfiguration)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start(html: html, continuation: continuation, alreadyCancelled: Task.isCancelled)
            }
        } onCancel: {
            Task { @MainActor in operation.finish(.cancelled) }
        }
    }

    private func start(
        html: String,
        continuation: CheckedContinuation<CGImage?, Never>,
        alreadyCancelled: Bool
    ) {
        self.continuation = continuation
        self.lifetime = SVGRasterizationLifetime(
            scheduleDeadline: Self.scheduleDeadline,
            onTermination: { [weak self] outcome in self?.terminate(outcome) }
        )
        guard !alreadyCancelled else {
            self.finish(.cancelled)
            return
        }
        self.view.navigationDelegate = self
        self.view.loadHTMLString(html, baseURL: nil)
    }

    private static func scheduleDeadline(
        _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: SVGRasterizer.svgRenderDeadline)
            } catch {
                return
            }
            fire()
        }
        return { task.cancel() }
    }

    private func finish(_ outcome: SVGRasterizationLifetime.Outcome) {
        _ = self.lifetime?.finish(outcome)
    }

    private func terminate(_ outcome: SVGRasterizationLifetime.Outcome) {
#if DEBUG
        if outcome == .timedOut {
            print("[SVGRasterizer] render deadline expired during \(self.phase.rawValue)")
        }
#endif
        self.view.stopLoading()
        self.view.navigationDelegate = nil
        self.view.removeFromSuperview()
        let continuation = self.continuation
        self.continuation = nil
        self.lifetime = nil
        let image = outcome == .completed ? self.renderedImage : nil
        self.renderedImage = nil
        continuation?.resume(returning: image)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let lifetime = self.lifetime, lifetime.outcome == nil else { return }
        self.phase = .snapshot
        webView.takeSnapshot(with: self.snapshotConfiguration) { [weak self] image, error in
            Task { @MainActor in
                guard let self, let lifetime = self.lifetime, lifetime.outcome == nil else { return }
                guard error == nil, let image = image?.cgImage else {
                    self.finish(.failed)
                    return
                }
                self.renderedImage = image
                self.finish(.completed)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.finish(.failed)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.finish(.failed)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    {
        decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
#endif
