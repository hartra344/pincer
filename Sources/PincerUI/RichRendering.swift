import CoreGraphics
import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Fenced ```mermaid diagrams and display math (`$$ … $$`, `\[ … \]`, ```math) drawn natively:
/// PincerKit turns the source into SVG (`MermaidSource`, `MathSource`) and the transcript shows it
/// through the inline-SVG image path from #200, so rasterizing is lazy, off the main thread on
/// macOS, and cached like any other image. No web engine or bundled JavaScript is involved.
enum RichBlock {
    enum Kind: String {
        case mermaid, math

        /// The disclosure title for the source under the rendered block.
        var sourceTitle: String {
            switch self {
            case .mermaid: L("Diagram source")
            case .math: L("Math source")
            }
        }

        var alt: String {
            switch self {
            case .mermaid: L("Mermaid diagram")
            case .math: L("Math expression")
            }
        }
    }

    struct Rendered {
        let kind: Kind
        let ref: ImageRef
        /// The SVG's own size in points; the transcript never draws it larger.
        let size: CGSize
    }

    static func kind(language: String) -> Kind? {
        if MermaidSource.isMermaid(language: language) { return .mermaid }
        if MathSource.isMath(language: language) { return .math }
        return nil
    }

    /// The rendered block for a fence, or nil when it isn't a rich language or its source isn't
    /// supported (it then stays a code block). Generated once per source and appearance.
    @MainActor static func render(language: String, code: String, dark: Bool) -> Rendered? {
        guard let kind = self.kind(language: language) else { return nil }
        return RichBlockCache.rendered(kind: kind, code: code, dark: dark)
    }

    /// Whether the app currently draws in Dark Mode, for picking the diagram palette.
    @MainActor static var isDark: Bool {
        #if os(macOS)
        (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let style = scene?.keyWindow?.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark
        #endif
    }
}

/// Small bounded cache, so re-laying-out a row doesn't regenerate, base64-encode and re-hash the
/// same diagram. Misses (unsupported source) are remembered too.
@MainActor
enum RichBlockCache {
    private static var entries: [String: RichBlock.Rendered?] = [:]
    private static let limit = 64

    static func rendered(kind: RichBlock.Kind, code: String, dark: Bool) -> RichBlock.Rendered? {
        let key = "\(kind.rawValue):\(dark ? "d" : "l"):\(code)"
        if let hit = self.entries[key] { return hit }
        let theme: RichRenderSVG.Theme = dark ? .dark : .light
        let svg: String? = switch kind {
        case .mermaid: MermaidSource.svg(for: code, theme: theme)
        case .math: MathSource.svg(for: code, theme: theme)
        }
        var rendered: RichBlock.Rendered?
        if let svg {
            let data = Data(svg.utf8)
            if let size = SVGSource.intrinsicSize(data), size.width > 0, size.height > 0 {
                let ref = ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: "image/svg+xml",
                                   alt: kind.alt, width: nil, height: nil)
                rendered = RichBlock.Rendered(kind: kind, ref: ref, size: size)
            }
        }
        if self.entries.count >= self.limit { self.entries.removeAll(keepingCapacity: true) }
        self.entries[key] = .some(rendered)
        return rendered
    }
}
