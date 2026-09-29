import CoreGraphics
import CoreText
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Shared pieces for the natively rendered rich blocks (```mermaid diagrams, LaTeX math). They're
/// generated as plain SVG and drawn through the #200 SVG path (`SVGSource`/`SVGRasterization`), so
/// no web engine or bundled JS is involved.
///
/// macOS's SVG decoder (CoreSVG) draws `<rect>`, `<path>`, `<line>`, `<polygon>`, `<circle>`,
/// `<ellipse>` and `<text>` with presentation attributes, but ignores `<marker>`, `<tspan
/// baseline-shift>`, CSS `<style>` and `foreignObject`. Generators stick to the supported subset:
/// arrowheads are explicit polygons, and sub/superscripts are separate `<text>` elements.
public enum RichRenderSVG {
    public enum Theme: String, Sendable, CaseIterable {
        case light, dark
    }

    /// Colors for one appearance, as SVG color strings.
    public struct Palette: Sendable {
        public let background: String
        public let border: String
        public let text: String
        public let secondaryText: String
        public let nodeFill: String
        public let nodeStroke: String
        public let edge: String
        public let accentFill: String
        public let noteFill: String
        public let noteStroke: String
    }

    public static func palette(_ theme: Theme) -> Palette {
        switch theme {
        case .light:
            Palette(background: "#FFFFFF", border: "#D9D9DE", text: "#1D1D1F", secondaryText: "#6E6E73",
                    nodeFill: "#EEF2FF", nodeStroke: "#6366F1", edge: "#55565C", accentFill: "#F5F5F7",
                    noteFill: "#FFF8DB", noteStroke: "#D4B200")
        case .dark:
            Palette(background: "#1C1C1E", border: "#3A3A3C", text: "#F2F2F7", secondaryText: "#AEAEB2",
                    nodeFill: "#2C2B4A", nodeStroke: "#8B8CF8", edge: "#AEAEB2", accentFill: "#2C2C2E",
                    noteFill: "#3A3320", noteStroke: "#B89B2E")
        }
    }

    /// Font family written into generated SVG; measurement uses Helvetica so boxes fit the text.
    public static let fontFamily = "Helvetica, Arial, sans-serif"

    /// Loads AppKit's font classes before the first CoreText font. In a process that hasn't touched
    /// `NSFont` yet (command-line checks, tests), creating a CTFont first leaves a cached typeface
    /// that later crashes `NSFont` (`-[__NSCFType initWithTypefaceInfo:…]`). The app has AppKit up already.
    public static let fontsReady: Void = {
        #if canImport(AppKit)
        _ = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif
    }()

    /// Rendered width of `text` in Helvetica at `size` points.
    public static func textWidth(_ text: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        _ = self.fontsReady
        let name = switch (bold, italic) {
        case (true, true): "Helvetica-BoldOblique"
        case (true, false): "Helvetica-Bold"
        case (false, true): "Helvetica-Oblique"
        case (false, false): "Helvetica"
        }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributed = CFAttributedStringCreate(
            nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// Escapes text for SVG character data and attribute values.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Formats a coordinate compactly (at most 2 decimals) for SVG output.
    public static func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", Double(rounded))
    }

    /// Wraps generated SVG body in a root `<svg>` with explicit size and a rounded card background.
    public static func document(width: CGFloat, height: CGFloat, theme: Theme, card: Bool = true, body: String) -> String {
        let palette = self.palette(theme)
        let w = self.number(width), h = self.number(height)
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(w)" height="\#(h)" viewBox="0 0 \#(w) \#(h)">"#
        if card {
            svg += #"<rect x="0.5" y="0.5" width="\#(self.number(width - 1))" height="\#(self.number(height - 1))" rx="8" fill="\#(palette.background)" stroke="\#(palette.border)"/>"#
        }
        svg += body
        svg += "</svg>"
        return svg
    }
}
