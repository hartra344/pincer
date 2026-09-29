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

/// Inline `$…$` / `\(…\)` math in running text, drawn as image attachments that sit on the baseline.
@MainActor
enum InlineMathText {
    struct Masked {
        let text: String
        /// Placeholder scalar → the span's LaTeX and its original source.
        let spans: [Unicode.Scalar: (latex: String, source: String)]
    }

    /// First private-use scalar used as a placeholder; one per span, so at most `limit` spans a paragraph.
    private nonisolated static let base: UInt32 = 0xF0000
    private nonisolated static let limit = 512

    nonisolated static func mask(_ text: String) -> Masked {
        let found = InlineMath.spans(in: text)
        guard !found.isEmpty, !text.unicodeScalars.contains(where: { $0.value >= base && $0.value < base + UInt32(limit) })
        else { return Masked(text: text, spans: [:]) }
        var out = ""
        var spans: [Unicode.Scalar: (latex: String, source: String)] = [:]
        var cursor = text.startIndex
        for (index, span) in found.prefix(limit).enumerated() {
            guard let scalar = Unicode.Scalar(base + UInt32(index)) else { break }
            out += text[cursor..<span.range.lowerBound]
            out.unicodeScalars.append(scalar)
            spans[scalar] = (span.latex, String(text[span.range]))
            cursor = span.range.upperBound
        }
        out += text[cursor...]
        return Masked(text: out, spans: spans)
    }

    /// Appends `string`, replacing placeholders with drawn math (or the original source if it can't be drawn).
    static func append(_ string: String, spans: [Unicode.Scalar: (latex: String, source: String)],
                       attributes: [NSAttributedString.Key: Any], font: PFont, color: PColor,
                       dark: Bool = RichBlock.isDark, to result: NSMutableAttributedString)
    {
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            result.append(NSAttributedString(string: pending, attributes: attributes))
            pending = ""
        }
        for scalar in string.unicodeScalars {
            guard let span = spans[scalar] else { pending.unicodeScalars.append(scalar); continue }
            if let attachment = self.attachment(span.latex, font: font, color: color, dark: dark) {
                flush()
                var attachmentAttributes = attributes
                attachmentAttributes[.attachment] = attachment
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: attachmentAttributes))
            } else {
                pending += span.source
            }
        }
        flush()
    }

    private static var cache: [String: NSTextAttachment?] = [:]
    private static let cacheLimit = 256

    /// One attachment object per formula, size and appearance, so an unchanged prefix of a streaming
    /// reply compares equal and TextKit doesn't re-lay it out.
    static func attachment(_ latex: String, font: PFont, color: PColor, dark: Bool = RichBlock.isDark) -> NSTextAttachment? {
        let cgColor = self.resolved(color, dark: dark)
        let components = (cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
        let key = "\(font.pointSize)|\(components)|\(latex)"
        if let hit = self.cache[key] { return hit }
        var attachment: NSTextAttachment?
        if let rendered = InlineMath.render(latex, fontSize: font.pointSize, color: cgColor, scale: self.scale) {
            let made = NSTextAttachment()
            #if os(macOS)
            made.image = NSImage(cgImage: rendered.image, size: rendered.size)
            #else
            made.image = UIImage(cgImage: rendered.image, scale: self.scale, orientation: .up)
            #endif
            made.bounds = CGRect(x: 0, y: -rendered.descent, width: rendered.size.width, height: rendered.size.height)
            attachment = made
        }
        if self.cache.count >= self.cacheLimit { self.cache.removeAll(keepingCapacity: true) }
        self.cache[key] = .some(attachment)
        return attachment
    }

    private static var scale: CGFloat {
        #if os(macOS)
        max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        #else
        3
        #endif
    }

    private static func resolved(_ color: PColor, dark: Bool) -> CGColor {
        #if os(macOS)
        var cgColor = color.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
        #else
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).cgColor
        #endif
    }
}
