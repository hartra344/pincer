import CoreGraphics
import CoreText
import Foundation

/// Inline math in running text: `$…$` and `\(…\)`, found with rules that leave prices and shell
/// variables alone, and drawn natively (CoreGraphics + CoreText) from the same layout as display math,
/// so it works synchronously during text layout on every platform.
public enum InlineMath {
    public struct Span: Equatable, Sendable {
        /// The whole span, delimiters included.
        public let range: Range<String.Index>
        public let latex: String
    }

    public struct Rendered: @unchecked Sendable {
        public let image: CGImage
        /// Size in points.
        public let size: CGSize
        /// How far the image reaches below the text baseline, in points.
        public let descent: CGFloat
    }

    static let maxLength = 500

    /// Inline math spans in one paragraph of Markdown source, skipping code spans and escaped dollars.
    ///
    /// `$…$` follows Pandoc's rules, a little stricter: the opening `$` is followed by a non-space and
    /// isn't preceded by a letter or digit; the closing `$` follows a non-space and isn't followed by a
    /// letter or digit; and a `$` that can't close ends the attempt. So "$5 and $10", "US$5" and
    /// "$HOME/$USER" stay text. `$$` is left alone (display math is handled per block).
    public static func spans(in text: String) -> [Span] {
        guard text.contains("$") || text.contains("\\(") else { return [] }
        let chars = Array(text)
        let indices = Array(text.indices) + [text.endIndex]
        var spans: [Span] = []
        var i = 0
        func escaped(_ at: Int) -> Bool {
            var n = 0, k = at - 1
            while k >= 0, chars[k] == "\\" { n += 1; k -= 1 }
            return n % 2 == 1
        }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                var j = i + run, closed = false
                while j < chars.count {
                    if chars[j] == "`" {
                        var r = 0
                        while j + r < chars.count, chars[j + r] == "`" { r += 1 }
                        if r == run { j += r; closed = true; break }
                        j += r
                    } else { j += 1 }
                }
                i = closed ? j : i + run
                continue
            }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(", !escaped(i) {
                var j = i + 2, found = -1
                while j + 1 < chars.count, chars[j] != "\n" {
                    if chars[j] == "\\", chars[j + 1] == ")", !escaped(j) { found = j; break }
                    j += 1
                }
                if found > i + 2 {
                    let latex = String(chars[(i + 2)..<found]).trimmingCharacters(in: .whitespaces)
                    if !latex.isEmpty, latex.count <= maxLength {
                        spans.append(Span(range: indices[i]..<indices[found + 2], latex: latex))
                        i = found + 2
                        continue
                    }
                }
                i += 2
                continue
            }
            if c == "$", !escaped(i) {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    var j = i
                    while j < chars.count, chars[j] == "$" { j += 1 }
                    i = j
                    continue
                }
                let opens = i + 1 < chars.count && !chars[i + 1].isWhitespace && !(i > 0 && isWord(chars[i - 1]))
                if opens {
                    var j = i + 1, found = -1
                    while j < chars.count, chars[j] != "\n" {
                        if chars[j] == "$", !escaped(j) {
                            let before = chars[j - 1]
                            let after: Character? = j + 1 < chars.count ? chars[j + 1] : nil
                            if !before.isWhitespace, after.map({ !isWord($0) && $0 != "$" }) ?? true { found = j }
                            break
                        }
                        j += 1
                    }
                    if found > i + 1, found - i - 1 <= maxLength {
                        spans.append(Span(range: indices[i]..<indices[found + 1], latex: String(chars[(i + 1)..<found])))
                        i = found + 1
                        continue
                    }
                }
            }
            i += 1
        }
        return spans
    }

    /// Whether `render` will draw `latex` (it parses and every command is known).
    public static func isDrawable(_ latex: String) -> Bool {
        guard latex.count <= maxLength, let root = MathParser.parseDocument(latex) else { return false }
        return root.unknownCount == 0
    }

    /// `text` as plain text the way the transcript shows it: Markdown resolved, and each drawable
    /// span as one object replacement character. Find counts matches in this, so its counts line up
    /// with what's drawn.
    public static func plainText(_ text: String) -> String {
        let found = self.spans(in: text)
        guard !found.isEmpty else { return String(MarkdownBlock.inline(text).characters) }
        var masked = ""
        var sources: [Unicode.Scalar: String] = [:]
        var cursor = text.startIndex
        for (index, span) in found.prefix(512).enumerated() {
            guard let scalar = Unicode.Scalar(0xF0000 + UInt32(index)) else { break }
            masked += text[cursor..<span.range.lowerBound]
            masked.unicodeScalars.append(scalar)
            sources[scalar] = self.isDrawable(span.latex) ? "\u{FFFC}" : String(text[span.range])
            cursor = span.range.upperBound
        }
        masked += text[cursor...]
        var out = ""
        for scalar in String(MarkdownBlock.inline(masked).characters).unicodeScalars {
            if let source = sources[scalar] { out += source } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    /// Draws `latex` in text style at `fontSize` in `color`, `scale` pixels per point. Nil when it
    /// doesn't parse or uses a command Pincer doesn't know, so the source stays as written.
    public static func render(_ latex: String, fontSize: CGFloat, color: CGColor, scale: CGFloat) -> Rendered? {
        guard latex.count <= maxLength, fontSize > 0, scale > 0,
              let root = MathParser.parseDocument(latex), root.unknownCount == 0
        else { return nil }
        let ctx = MathLayout.Ctx(size: fontSize, base: fontSize, depth: 0, face: nil, inline: true)
        let box = MathLayout.layout(root.node, ctx)
        guard box.w > 0 else { return nil }
        let pad: CGFloat = 1
        let size = CGSize(width: ceil(box.w + pad * 2), height: ceil(box.asc + box.desc + pad * 2))
        let pixels = (width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)))
        guard pixels.width > 0, pixels.height > 0, pixels.width <= 8_000, pixels.height <= 2_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Box coordinates run down from the baseline; flip into CoreGraphics' upward y.
        let baseline = size.height - pad - box.asc
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + pad, y: baseline - y) }
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        _ = RichRenderSVG.fontsReady
        for prim in box.prims {
            switch prim {
            case let .text(x, y, s, fontSize, face, _):
                let font = CTFontCreateWithName(MathLayout.fontName(face) as CFString, fontSize, nil)
                let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
                guard let string = CFAttributedStringCreate(nil, s as CFString, attributes) else { continue }
                let line = CTLineCreateWithAttributedString(string)
                context.textMatrix = .identity
                context.textPosition = point(x, y)
                CTLineDraw(line, context)
            case let .line(x1, y1, x2, y2, w):
                context.setLineWidth(w)
                context.move(to: point(x1, y1))
                context.addLine(to: point(x2, y2))
                context.strokePath()
            case let .path(segments, w):
                context.setLineWidth(w)
                for segment in segments {
                    let p = segment.pts.map { point($0.x, $0.y) }
                    switch segment.cmd {
                    case "M" where p.count >= 1: context.move(to: p[0])
                    case "L" where p.count >= 1: p.forEach { context.addLine(to: $0) }
                    case "Q" where p.count >= 2: context.addQuadCurve(to: p[1], control: p[0])
                    case "C" where p.count >= 3: context.addCurve(to: p[2], control1: p[0], control2: p[1])
                    default: break
                    }
                }
                context.strokePath()
            case let .dot(x, y, r):
                let c = point(x, y)
                context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, size: size, descent: box.desc + pad)
    }
}
