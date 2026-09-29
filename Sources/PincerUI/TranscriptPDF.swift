import CoreText
import Foundation
import PincerKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Renders an exported transcript as a paginated US Letter PDF with CoreText, so it works on macOS and iOS.
enum TranscriptPDF {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func render(markdown: String, title: String) -> Data {
        let text = self.attributed(markdown)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: self.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: title] as CFDictionary)
        else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let length = CFAttributedStringGetLength(text)
        let area = box.insetBy(dx: self.margin, dy: self.margin)
        let path = CGPath(rect: area, transform: nil)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame).length
            // A frame that fits nothing would loop forever; skip a character instead.
            location += max(visible, 1)
        } while location < length
        context.closePDF()
        return data as Data
    }

    static func attributed(_ markdown: String) -> NSAttributedString {
        let body = PFont.systemFont(ofSize: 11)
        let mono = PFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let out = NSMutableAttributedString()
        var inCode = false
        var thinking = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            var font = body
            var text = line
            var gray = false
            if !inCode, line == "---" || line == "</details>" {
                if line == "---" { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
                if line == "</details>" { thinking = false }
                continue
            }
            if !inCode, line.hasPrefix("<details><summary>"), line.hasSuffix("</summary>") {
                text = String(line.dropFirst("<details><summary>".count).dropLast("</summary>".count))
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: PFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: Self.gray]))
                thinking = true
                continue
            }
            gray = thinking
            if inCode {
                font = mono
            } else if let level = Self.headingLevel(line) {
                text = String(line.dropFirst(level + 1))
                font = PFont.systemFont(ofSize: [20, 16, 14, 12][min(level, 4) - 1], weight: .bold)
            }
            let piece: NSAttributedString
            if inCode || text.isEmpty {
                piece = NSAttributedString(string: text, attributes: [.font: font])
            } else if let parsed = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                piece = Self.styled(parsed, base: font)
            } else {
                piece = NSAttributedString(string: text, attributes: [.font: font])
            }
            let start = out.length
            out.append(piece)
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            out.addAttribute(.foregroundColor, value: gray ? Self.gray : Self.black,
                             range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func styled(_ text: AttributedString, base: PFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = PFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
                } else if intent.contains(.stronglyEmphasized) {
                    font = PFont.systemFont(ofSize: base.pointSize, weight: .bold)
                } else if intent.contains(.emphasized) {
                    font = Self.italic(base)
                }
            }
            out.append(NSAttributedString(string: piece, attributes: [.font: font]))
        }
        return out
    }

    #if canImport(AppKit)
    private static func italic(_ font: PFont) -> PFont { NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    #else
    private static func italic(_ font: PFont) -> PFont { PFont.italicSystemFont(ofSize: font.pointSize) }
    #endif

    #if canImport(AppKit)
    private static let black = NSColor.black
    private static let gray = NSColor.darkGray
    #else
    private static let black = UIColor.black
    private static let gray = UIColor.darkGray
    #endif
}
