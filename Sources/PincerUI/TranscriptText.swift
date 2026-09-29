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

    static let segmentCapacity = 3000

    private static var segmentCache = LRUCache<Key, [Segment]>(capacity: TranscriptText.segmentCapacity)
    private static var cacheGeneration = -1

    /// Number of cached committed-message segment lists, for tests.
    static var segmentCacheCount: Int { self.segmentCache.count }

    // MARK: Building

    static func markdown(_ source: String, tone: Tone) -> [Segment] {
        if self.cacheGeneration != TranscriptStyle.generation {
            self.segmentCache.removeAll()
            self.cacheGeneration = TranscriptStyle.generation
        }
        let key = Key(source: source, tone: tone)
        if let cached = self.segmentCache.value(for: key) { return cached }
        let segments = self.build(MarkdownCache.blocks(source), tone: tone)
        self.segmentCache.set(segments, for: key)
        return segments
    }

    // MARK: Live rows

    /// One piece of a streaming message. Frozen pieces are built once and keep their identity across
    /// flushes; the tail is rebuilt every time.
    struct LiveSegment {
        let segment: Segment
        let isFrozen: Bool
        /// Extra space above, so the split reads like the single view a committed message gets.
        let extraSpacing: CGFloat
    }

    private struct FrozenChunk {
        let segments: [Segment]
        let startsWithHeading: Bool
    }

    private struct HeightKey: Hashable {
        let object: ObjectIdentifier
        let width: CGFloat
        let exact: Bool
    }

    /// What is kept for one streaming row: its frozen text (up to its last cut), the chunks built from it,
    /// and their measured heights.
    private struct LiveState {
        var owner: ObjectIdentifier?
        var tone: Tone
        var generation: Int
        var frozenText = ""
        var chunks: [FrozenChunk] = []
        var heights: [HeightKey: (text: NSAttributedString, height: CGFloat)] = [:]
        var lastUse = 0
    }

    /// Enough for a few chats streaming at once (windows); the least recently used row is dropped past it.
    static let liveRowCapacity = 4
    private static var liveStates: [String: LiveState] = [:]
    private static var liveClock = 0
    /// The row whose heights `liveSize` records: the one `liveMarkdown` last served.
    private static var heightRow: String?

    /// Entries in the per-live-row memos, for tests.
    static var liveMemoCount: (rows: Int, chunks: Int, heights: Int) {
        (self.liveStates.count, self.liveStates.values.reduce(0) { $0 + $1.chunks.count },
         self.liveStates.values.reduce(0) { $0 + $1.heights.count })
    }

    /// Forgets a live row's memos once it commits.
    static func endLive(row: String) {
        self.liveStates[row] = nil
    }

    /// Forgets the memos of `owner`'s rows other than `keeping` (its row that is still streaming, if any).
    static func endLive(owner: ObjectIdentifier, keeping: String?) {
        guard !self.liveStates.isEmpty else { return }
        for (row, state) in self.liveStates where state.owner == owner && row != keeping { self.liveStates[row] = nil }
    }

    /// Whether `source` still starts with the frozen text (a memcmp, not a Character walk).
    private static func extends(_ frozen: String, _ source: String) -> Bool {
        var known = frozen
        var new = source
        let count = known.utf8.count
        guard new.utf8.count >= count else { return false }
        return known.withUTF8 { old in
            new.withUTF8 { current in count == 0 || memcmp(old.baseAddress!, current.baseAddress!, count) == 0 }
        }
    }

    /// A streaming message as frozen chunks plus a fresh tail. Never touches the shared caches.
    /// Only the text since the last cut is scanned and parsed; frozen chunks are reused as they are.
    static func liveMarkdown(_ source: String, tone: Tone, row: String, owner: ObjectIdentifier? = nil) -> [LiveSegment] {
        self.liveClock += 1
        var state = self.liveStates[row] ?? LiveState(owner: owner, tone: tone, generation: TranscriptStyle.generation)
        if state.tone != tone || state.generation != TranscriptStyle.generation || !self.extends(state.frozenText, source) {
            state = LiveState(owner: owner, tone: tone, generation: TranscriptStyle.generation)
        }
        state.lastUse = self.liveClock
        var start = source.utf8.index(source.startIndex, offsetBy: state.frozenText.utf8.count)
        for cut in MarkdownBlock.streamingFreezePoints(source, from: start) where cut > start && cut <= source.endIndex {
            let text = String(source[start..<cut])
            start = cut
            let blocks = MarkdownBlock.parse(text)
            var heading = false
            if case .heading = blocks.first { heading = true }
            state.chunks.append(FrozenChunk(segments: self.build(blocks, tone: tone, cached: false), startsWithHeading: heading))
            state.frozenText += text
        }
        self.liveStates[row] = state
        self.heightRow = row
        if self.liveStates.count > self.liveRowCapacity,
           let oldest = self.liveStates.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
        {
            self.liveStates[oldest] = nil
        }
        var result: [LiveSegment] = []
        var previousEndsWithText = false
        func add(_ segments: [Segment], frozen: Bool, startsWithHeading: Bool) {
            for (index, segment) in segments.enumerated() {
                var extra: CGFloat = 0
                if index == 0, startsWithHeading, previousEndsWithText, case .text = segment { extra = 2 }
                result.append(LiveSegment(segment: segment, isFrozen: frozen, extraSpacing: extra))
            }
            if let last = segments.last {
                if case .text = last { previousEndsWithText = true } else { previousEndsWithText = false }
            }
        }
        for chunk in state.chunks { add(chunk.segments, frozen: true, startsWithHeading: chunk.startsWithHeading) }
        if start < source.endIndex {
            let blocks = MarkdownBlock.parse(String(source[start...]))
            var heading = false
            if case .heading = blocks.first { heading = true }
            add(self.build(blocks, tone: tone, cached: false), frozen: false, startsWithHeading: heading)
        }
        return result
    }

    /// Size of a live segment's text. Frozen text is measured once per width. Text runs report
    /// their exact height, so many small views add up to what one committed view measures.
    static func liveSize(_ string: NSAttributedString, width: CGFloat, frozen: Bool, exact: Bool) -> CGSize {
        guard frozen else { return self.size(string, width: width, exact: exact) }
        let key = HeightKey(object: ObjectIdentifier(string), width: width, exact: exact)
        if let row = self.heightRow, let known = self.liveStates[row]?.heights[key] { return CGSize(width: width, height: known.height) }
        let size = self.size(string, width: width, exact: exact)
        if let row = self.heightRow { self.liveStates[row]?.heights[key] = (string, size.height) }
        return size
    }

    static func color(for tone: Tone) -> PColor {
        switch tone {
        case .primary: TranscriptColors.label
        case .secondary: TranscriptColors.secondary
        case .error: TranscriptColors.red
        }
    }

    private static func build(_ blocks: [MarkdownBlock], tone: Tone, cached: Bool = true) -> [Segment] {
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
                append(self.inline(text, font: style.body, color: color, cached: cached), spacingBefore: TranscriptMetrics.blockSpacing)
            case let .heading(level, text):
                let font = level == 1 ? style.title2 : level == 2 ? style.title3 : style.headline
                append(self.inline(text, font: font, color: color, cached: cached), spacingBefore: TranscriptMetrics.blockSpacing + 2)
            case let .list(items, ordered):
                let markers = items.indices.map { ordered ? "\($0 + 1)." : "•" }
                let markerAttributes: [NSAttributedString.Key: Any] = [.font: style.listMarker, .foregroundColor: TranscriptColors.secondary]
                let markerWidth = markers.map { ceil(($0 as NSString).size(withAttributes: markerAttributes).width) }.max() ?? 0
                for (index, item) in items.enumerated() {
                    let indent = CGFloat(item.indent) * 14
                    let textStart = indent + markerWidth + 6
                    let line = NSMutableAttributedString(string: markers[index], attributes: markerAttributes)
                    line.append(NSAttributedString(string: "\t", attributes: [.font: style.body]))
                    line.append(self.inline(item.text, font: style.body, color: color, cached: cached))
                    append(line, spacingBefore: index == 0 ? TranscriptMetrics.blockSpacing : 4) { paragraph in
                        paragraph.firstLineHeadIndent = indent
                        paragraph.headIndent = textStart
                        paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: textStart)]
                        paragraph.defaultTabInterval = 28
                    }
                }
            case let .quote(text):
                flush()
                let quote = self.inline(text, font: style.body, color: TranscriptColors.secondary, cached: cached)
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
                        let cell = self.inline(text, font: font, color: color, cached: cached)
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
    static func inline(_ text: String, font: PFont, color: PColor, cached: Bool = true) -> NSMutableAttributedString {
        // Inline math is swapped for placeholders before Markdown sees it (so `_` and `*` inside it
        // aren't read as emphasis), then drawn as image attachments.
        let math = InlineMathText.mask(text)
        let parsed = cached ? MarkdownCache.inline(math.text) : MarkdownBlock.inline(math.text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let string = MarkdownBlock.softBreaks(String(parsed[run.range].characters))
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
            if math.spans.isEmpty {
                result.append(NSAttributedString(string: string, attributes: attributes))
            } else {
                InlineMathText.append(string, spans: math.spans, attributes: attributes, font: runFont,
                                      color: color, to: result)
            }
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
    static func size(_ string: NSAttributedString, width: CGFloat, exact: Bool = false) -> CGSize {
        guard string.length > 0, width > 0 else { return .zero }
        let manager = self.layoutManager
        let container = manager.textContainers[0]
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        self.storage.setAttributedString(string)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return exact ? CGSize(width: ceil(used.width), height: used.height) : CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Width of `string` on one line, ignoring paragraph alignment.
    static func naturalWidth(_ string: NSAttributedString) -> CGFloat {
        guard string.length > 0 else { return 0 }
        let unaligned = NSMutableAttributedString(attributedString: string)
        unaligned.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: unaligned.length))
        return self.size(unaligned, width: .greatestFiniteMagnitude).width
    }
}

extension NSTextStorage {
    /// Makes the storage hold `text`. When `keepingPrefix` is set and the storage's start already
    /// matches (characters and attributes), only the rest is replaced, so TextKit re-lays out just that
    /// part; a growing reply then costs the size of its newest text, not of the whole message.
    @MainActor
    func update(to text: NSAttributedString, keepingPrefix: Bool) {
        let keep = keepingPrefix ? TranscriptText.commonPrefixLength(self, text) : 0
        guard keep > 0 else {
            self.setAttributedString(text)
            return
        }
        let tail = NSRange(location: keep, length: text.length - keep)
        self.beginEditing()
        self.replaceCharacters(in: NSRange(location: keep, length: self.length - keep),
                               with: text.attributedSubstring(from: tail))
        self.endEditing()
    }
}

extension TranscriptText {
    /// UTF-16 length of the start both strings share, characters and attributes alike (to run granularity).
    static func commonPrefixLength(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        let limit = min(old.length, new.length)
        guard limit > 0 else { return 0 }
        let a = old.string as NSString
        let b = new.string as NSString
        var same = 0
        // Compare in chunks first so a long shared start costs little, then locate the exact character.
        let step = 512
        while same < limit {
            let length = min(step, limit - same)
            let range = NSRange(location: same, length: length)
            if a.substring(with: range) != b.substring(with: range) { break }
            same += length
        }
        if same < limit {
            var low = same
            while low < limit, a.character(at: low) == b.character(at: low) { low += 1 }
            same = low
        }
        var location = 0
        while location < same {
            var oldRun = NSRange()
            var newRun = NSRange()
            let span = NSRange(location: location, length: same - location)
            let oldAttributes = old.attributes(at: location, longestEffectiveRange: &oldRun, in: span)
            let newAttributes = new.attributes(at: location, longestEffectiveRange: &newRun, in: span)
            if !(oldAttributes as NSDictionary).isEqual(to: newAttributes) { return location }
            location += min(oldRun.length, newRun.length)
        }
        return same
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
