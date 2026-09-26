import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import WebKit
#endif

/// ImageIO can't decode SVG, so agent-drawn SVGs (charts, illustrations) are rasterized here.
/// macOS draws them with `NSImage`; iOS has no public SVG decoder, so it renders the SVG as an
/// `<img>` in a script-less web view, where SVG can't run scripts or load external resources.
@MainActor
public enum SVGRasterizer {
    /// Transcript cells are at most ~400pt wide, so this stays sharp at 3x without holding a huge
    /// bitmap per SVG. Full-size previews re-render the vector at their own size instead.
    nonisolated static let thumbnailPixelSize: CGFloat = 1200

    public nonisolated static func isSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let tag = head.range(of: "<svg") else { return false }
        return !head[..<tag.lowerBound].contains("<html")
    }

    public static func rasterize(_ data: Data) async -> CGImage? {
        guard let intrinsic = self.intrinsicSize(data) else { return nil }
        return await self.rasterize(data, intrinsic: intrinsic, pixels: self.pixelSize(for: intrinsic, fitting: CGSize(width: self.thumbnailPixelSize, height: self.thumbnailPixelSize)))
    }

    /// Renders the SVG as large as fits in `bounds` (in pixels), keeping its aspect ratio.
    public static func rasterize(_ data: Data, fitting bounds: CGSize) async -> CGImage? {
        guard let intrinsic = self.intrinsicSize(data), bounds.width >= 1, bounds.height >= 1 else { return nil }
        return await self.rasterize(data, intrinsic: intrinsic, pixels: self.pixelSize(for: intrinsic, fitting: bounds))
    }

    private static func rasterize(_ data: Data, intrinsic: CGSize, pixels: CGSize) async -> CGImage? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: pixels)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return self.redraw(cgImage, size: pixels)
        #else
        return await WebSnapshotter.snapshot(svg: data, size: intrinsic, pixels: pixels)
        #endif
    }

    /// Scales the SVG's own size to fill `bounds`, keeping its aspect ratio.
    nonisolated static func pixelSize(for size: CGSize, fitting bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
    }

    /// Root `<svg>` size from `width`/`height`, falling back to `viewBox`, then the CSS default 300×150.
    public nonisolated static func intrinsicSize(_ data: Data) -> CGSize? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let start = text.range(of: "<svg", options: .caseInsensitive),
              let end = text[start.upperBound...].firstIndex(of: ">")
        else { return nil }
        let tag = String(text[start.upperBound..<end])
        func attribute(_ name: String) -> String? {
            let pattern = #"(?:^|\s)"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
            else { return nil }
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
            }
            return nil
        }
        func length(_ value: String?) -> CGFloat? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.hasSuffix("%"),
                  let number = Double(value.prefix(while: { $0.isNumber || $0 == "." })), number > 0
            else { return nil }
            return CGFloat(number)
        }
        let viewBox = attribute("viewBox")?
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        let boxSize = viewBox.flatMap { $0.count == 4 && $0[2] > 0 && $0[3] > 0 ? CGSize(width: $0[2], height: $0[3]) : nil }
        let width = length(attribute("width"))
        let height = length(attribute("height"))
        switch (width, height, boxSize) {
        case let (width?, height?, _): return CGSize(width: width, height: height)
        case let (width?, nil, box?): return CGSize(width: width, height: width * box.height / box.width)
        case let (nil, height?, box?): return CGSize(width: height * box.width / box.height, height: height)
        case let (nil, nil, box?): return box
        default: return CGSize(width: 300, height: 150)
        }
    }

    /// Draws into a plain 8-bit sRGB bitmap: `NSImage` hands back a float, screen-profile image.
    nonisolated static func redraw(_ image: CGImage, size: CGSize) -> CGImage? {
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

    static func snapshot(svg: Data, size: CGSize, pixels: CGSize) async -> CGImage? {
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
        defer { view.removeFromSuperview() }

        let delegate = WebSnapshotter()
        view.navigationDelegate = delegate
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(Int(size.width)), initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        img{display:block;width:\(size.width)px;height:\(size.height)px}</style></head>
        <body><img src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
        """
        let loaded = await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        guard loaded else { return nil }
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(pixels.width / view.traitCollection.displayScale))
        snapshotConfiguration.afterScreenUpdates = true
        guard let image = try? await view.takeSnapshot(configuration: snapshotConfiguration).cgImage else { return nil }
        return SVGRasterizer.redraw(image, size: pixels)
    }

    private func finish(_ loaded: Bool) {
        self.continuation?.resume(returning: loaded)
        self.continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { self.finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
