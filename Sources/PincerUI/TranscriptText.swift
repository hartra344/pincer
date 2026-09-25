import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Turns message text into attributed strings for native text views, and measures them with the
/// same TextKit 1 setup the views use, so a row's computed height is exactly what gets drawn.
@MainActor
enum TranscriptText {
    /// A run of message content drawn by one view. Consecutive paragraphs, headings and lists share
    /// one text view, so selection flows across them.
    enum Segment {
        case text(NSAttributedString)
        case quote(NSAttributedString)
        case code(language: String, code: String, text: NSAttributedString)
        case table(Table)
        case rule
    }

    struct Table {
        /// Row 0 is the header. Every row has one cell per column.
        let cells: [[NSAttributedString]]
        let alignments: [MarkdownBlock.Alignment]
        /// The table as tab-separated text, for copying.
        let plainText: String
    }

    enum Tone: Hashable { case primary, secondary, error }

    private struct Key: Hashable {
        let source: String
        let tone: Tone
    }

    private static var segmentCache: [Key: [Segment]] = [:]
    private static var cacheGeneration = -1

    // MARK: Building

    static func markdown(_ source: String, tone: Tone) -> [Segment] {
        if self.cacheGeneration != TranscriptStyle.generation {
            self.segmentCache.removeAll()
            self.cacheGeneration = TranscriptStyle.generation
        }
        let key = Key(source: source, tone: tone)
        if let cached = self.segmentCache[key] { return cached }
        let segments = self.build(MarkdownCache.blocks(source), tone: tone)
        if self.segmentCache.count > 3000 { self.segmentCache.removeAll(keepingCapacity: true) }
        self.segmentCache[key] = segments
        return segments
    }

    static func color(for tone: Tone) -> PColor {
        switch tone {
        case .primary: TranscriptColors.label
        case .secondary: TranscriptColors.secondary
        case .error: TranscriptColors.red
        }
    }

    private static func build(_ blocks: [MarkdownBlock], tone: Tone) -> [Segment] {
        let style = TranscriptStyle.shared
        let color = self.color(for: tone)
        var segments: [Segment] = []
        var current = NSMutableAttributedString()

        func flush() {
            if current.length > 0 {
                segments.append(.text(current))
                current = NSMutableAttributedString()
            }
        }
        /// Appends one paragraph to the current text run, spaced from the previous one.
        func append(_ paragraph: NSMutableAttributedString, spacingBefore: CGFloat, configure: (NSMutableParagraphStyle) -> Void = { _ in }) {
            let paragraphStyle = NSMutableParagraphStyle()
            if current.length > 0 {
                paragraphStyle.paragraphSpacingBefore = spacingBefore
                current.append(NSAttributedString(string: "\n", attributes: [.font: style.body]))
            }
            configure(paragraphStyle)
            paragraph.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: paragraph.length))
            current.append(paragraph)
        }

        for block in blocks {
            switch block {
            case let .paragraph(text):
                append(self.inline(text, font: style.body, color: color), spacingBefore: TranscriptMetrics.blockSpacing)
            case let .heading(level, text):
                let font = level == 1 ? style.title2 : level == 2 ? style.title3 : style.headline
                append(self.inline(text, font: font, color: color), spacingBefore: TranscriptMetrics.blockSpacing + 2)
            case let .list(items, ordered):
                let markers = items.indices.map { ordered ? "\($0 + 1)." : "•" }
                let markerAttributes: [NSAttributedString.Key: Any] = [.font: style.listMarker, .foregroundColor: TranscriptColors.secondary]
                let markerWidth = markers.map { ceil(($0 as NSString).size(withAttributes: markerAttributes).width) }.max() ?? 0
                for (index, item) in items.enumerated() {
                    let indent = CGFloat(item.indent) * 14
                    let textStart = indent + markerWidth + 6
                    let line = NSMutableAttributedString(string: markers[index], attributes: markerAttributes)
                    line.append(NSAttributedString(string: "\t", attributes: [.font: style.body]))
                    line.append(self.inline(item.text, font: style.body, color: color))
                    append(line, spacingBefore: index == 0 ? TranscriptMetrics.blockSpacing : 4) { paragraph in
                        paragraph.firstLineHeadIndent = indent
                        paragraph.headIndent = textStart
                        paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: textStart)]
                        paragraph.defaultTabInterval = 28
                    }
                }
            case let .quote(text):
                flush()
                let quote = self.inline(text, font: style.body, color: TranscriptColors.secondary)
                segments.append(.quote(quote))
            case let .code(language, code):
                flush()
                let text = NSAttributedString(string: code, attributes: [.font: style.code, .foregroundColor: TranscriptColors.label])
                segments.append(.code(language: language?.isEmpty == false ? language! : "code", code: code, text: text))
            case .rule:
                flush()
                segments.append(.rule)
            case let .table(header, alignments, rows):
                flush()
                let columns = header.count
                func row(_ cells: [String], font: PFont) -> [NSAttributedString] {
                    (0..<columns).map { column in
                        let text = column < cells.count ? cells[column] : ""
                        let cell = self.inline(text, font: font, color: color)
                        let alignment = column < alignments.count ? alignments[column] : .leading
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.alignment = alignment == .trailing ? .right : alignment == .center ? .center : .natural
                        cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
                        return cell
                    }
                }
                let cells = [row(header, font: style.bodySemibold)] + rows.map { row($0, font: style.body) }
                let plain = ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
                segments.append(.table(Table(cells: cells, alignments: alignments, plainText: plain)))
            }
        }
        flush()
        return segments
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) as attributes on `font`.
    static func inline(_ text: String, font: PFont, color: PColor) -> NSMutableAttributedString {
        let parsed = MarkdownCache.inline(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            // Soft line breaks stay inside the paragraph, so paragraph spacing applies only between blocks.
            let string = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = PFont.monospacedSystemFont(ofSize: (font.pointSize * 0.92).rounded(), weight: .regular)
                    attributes[.backgroundColor] = TranscriptColors.fill
                }
                runFont = TranscriptStyle.withTraits(runFont, bold: intent.contains(.stronglyEmphasized),
                                                     italic: intent.contains(.emphasized))
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

    static func plain(_ text: String, font: PFont, color: PColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: Measuring

    private static let storage = NSTextStorage()
    private static let layoutManager: NSLayoutManager = {
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        TranscriptText.storage.addLayoutManager(manager)
        return manager
    }()

    /// Size of `string` wrapped to `width` (unwrapped when width is infinite), rounded up to points.
    static func size(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        guard string.length > 0, width > 0 else { return .zero }
        let manager = self.layoutManager
        let container = manager.textContainers[0]
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        self.storage.setAttributedString(string)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Width of `string` on one line, ignoring paragraph alignment.
    static func naturalWidth(_ string: NSAttributedString) -> CGFloat {
        guard string.length > 0 else { return 0 }
        let unaligned = NSMutableAttributedString(attributedString: string)
        unaligned.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: unaligned.length))
        return self.size(unaligned, width: .greatestFiniteMagnitude).width
    }
}

/// Configures a TextKit 1 stack exactly like `TranscriptText`'s measuring one.
@MainActor
enum TranscriptTextKit {
    /// The storage is the root of a TextKit 1 stack (it owns the layout manager, which owns the
    /// container), so whoever uses the container has to keep the storage alive.
    static func stack(wraps: Bool) -> (NSTextStorage, NSTextContainer) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: wraps ? 100 : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (storage, container)
    }
}
