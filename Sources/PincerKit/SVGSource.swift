import CoreGraphics
import Foundation

/// Sniffing and sizing for SVG data. UI-free, so the transcript builder and the image loader can use it;
/// drawing lives in PincerUI (`SVGRasterizer`), which registers itself as `SVGRasterization.provider`.
public enum SVGSource {
    /// Transcript cells are at most ~400pt wide, so this stays sharp at 3x without holding a huge
    /// bitmap per SVG. Full-size previews re-render the vector at their own size instead.
    public static let thumbnailPixelSize: CGFloat = 1200

    /// The SVG in a fenced code block the transcript draws as an image instead (```svg, or any fence
    /// holding a whole `<svg>…</svg>`), or nil. Unfinished ones, mid-stream, stay code until their
    /// closing tag arrives.
    public static func inlineSource(language: String, code: String) -> String? {
        let lang = language.lowercased()
        guard lang == "svg" || lang == "xml" || lang == "html" || lang == "code" else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "</svg>", options: [.caseInsensitive, .backwards]) != nil,
              self.isSVG(Data(trimmed.utf8)),
              lang == "svg" || trimmed.lowercased().hasPrefix("<svg") || trimmed.hasPrefix("<?xml")
        else { return nil }
        return trimmed
    }

    public static func isSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let tag = head.range(of: "<svg") else { return false }
        return !head[..<tag.lowerBound].contains("<html")
    }

    /// Scales the SVG's own size to fill `bounds`, keeping its aspect ratio.
    public static func pixelSize(for size: CGSize, fitting bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
    }

    /// Root `<svg>` size from `width`/`height`, falling back to `viewBox`, then the CSS default 300×150.
    public static func intrinsicSize(_ data: Data) -> CGSize? {
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
}

/// Draws SVG data; implemented by PincerUI because ImageIO can't decode SVG.
public protocol SVGRasterizing: Sendable {
    /// Renders the SVG as large as fits in `bounds` (pixels), keeping its aspect ratio.
    func rasterize(_ data: Data, fitting bounds: CGSize) async -> CGImage?
}

/// The injected rasterizer. Nil (drawing nothing) until PincerUI installs one at launch.
public enum SVGRasterization {
    @MainActor public static var provider: (any SVGRasterizing)?

    /// The SVG as a thumbnail-sized bitmap, or nil when it can't be drawn.
    @MainActor public static func rasterize(_ data: Data) async -> CGImage? {
        let bounds = CGSize(width: SVGSource.thumbnailPixelSize, height: SVGSource.thumbnailPixelSize)
        return await self.provider?.rasterize(data, fitting: bounds)
    }
}
