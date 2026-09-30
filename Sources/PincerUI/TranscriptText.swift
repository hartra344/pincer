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

    /// The appearance is part of the key only for text with inline math, which bakes a resolved color
    /// into its attachments; other text is appearance independent, so a Dark Mode flip keeps its sizes.
    struct Key: Hashable {
        let source: String
        let tone: Tone
        let dark: Bool

        init(source: String, tone: Tone, dark: Bool) {
            self.source = source
            self.tone = tone
            self.dark = Self.bakesAppearance(source) ? dark : false
        }

        nonisolated static func bakesAppearance(_ source: String) -> Bool { source.contains("$") || source.contains("\\(") }
    }

    /// How inline text reaches Markdown parsing and inline math. Main uses the shared caches and draws
    /// math; the premeasure worker parses uncached and draws math from the same lock-protected cache.
    struct BuildHooks {
        var parse: (String) -> AttributedString
        var math: ((String, [Unicode.Scalar: (latex: String, source: String)], [NSAttributedString.Key: Any],
                    PFont, PColor, NSMutableAttributedString) -> Void)?

        @MainActor static func main(cached: Bool, dark: Bool = RichBlock.isDark) -> BuildHooks {
            let scale = InlineMathText.scale
            return BuildHooks(parse: { cached ? MarkdownCache.inline($0) : MarkdownBlock.inline($0) },
                       math: { string, spans, attributes, font, color, result in
                           InlineMathText.append(string, spans: spans, attributes: attributes, font: font, color: color, dark: dark,
                                                 scale: scale, to: result)
                       })
        }

        /// Off-main hooks: parses uncached and draws math from the lock-protected cache at `env`'s appearance and scale.
        nonisolated static func worker(env: TextBuildEnvironment) -> BuildHooks {
            let dark = env.dark, scale = env.mathScale
            return BuildHooks(parse: MarkdownBlock.inline,
                              math: { string, spans, attributes, font, color, result in
                                  InlineMathText.append(string, spans: spans, attributes: attributes, font: font, color: color,
                                                        dark: dark, scale: scale, to: result)
                              })
        }
    }

    static let segmentCapacity = 3000

    private static var segmentCache = LRUCache<Key, [Segment]>(capacity: TranscriptText.segmentCapacity)
    private static var cacheGeneration = -1

    static let heightMemoCapacity = 6000

    struct MemoKey: Hashable {
        let object: ObjectIdentifier
        let width: CGFloat
        let exact: Bool
    }

    /// Sizes of cached segments' strings, so relaying out a row whose text is unchanged (or whose sizes
    /// the premeasure worker computed) costs no TextKit pass. Entries hold their string so an identifier
    /// can't be reused while the size is remembered.
    private static var heightMemo = LRUCache<MemoKey, (text: NSAttributedString, size: CGSize)>(capacity: TranscriptText.heightMemoCapacity)
    private static let measurer = TranscriptTextMeasurer()

    /// TextKit passes run on the main thread and sizes served from the memo, for tests and probes.
    private(set) static var measureStats: (mainLayouts: Int, memoHits: Int) = (0, 0)

    static func resetMeasureStats() { self.measureStats = (0, 0) }

    /// Width the text of a quote block wraps at inside a content column of `width`.
    nonisolated static func quoteWidth(for width: CGFloat) -> CGFloat { max(width - 11, 20) }

    /// Whether `key`'s segments are cached and every size a row lays them out with at `contentWidth`
    /// is remembered, so laying the row out costs no TextKit pass.
    static func isWarm(_ key: Key, contentWidth: CGFloat) -> Bool {
        self.syncGeneration()
        guard let segments = self.segmentCache.value(for: key) else { return false }
        func known(_ text: NSAttributedString, _ width: CGFloat) -> Bool {
            text.length == 0 || self.heightMemo.value(for: MemoKey(object: ObjectIdentifier(text), width: width, exact: false)) != nil
        }
        for segment in segments {
            switch segment {
            case let .text(text): if !known(text, contentWidth) { return false }
            case let .quote(text): if !known(text, self.quoteWidth(for: contentWidth)) { return false }
            case let .code(_, _, text): if !known(text, .greatestFiniteMagnitude) { return false }
            case let .table(table):
                var naturals = Array(repeating: CGFloat(0), count: table.cells.first?.count ?? 0)
                for row in table.cells {
                    for (column, cell) in row.enumerated() where cell.length > 0 {
                        guard let hit = self.heightMemo.value(for: MemoKey(object: ObjectIdentifier(cell), width: -1, exact: false))
                        else { return false }
                        naturals[column] = max(naturals[column], hit.size.width)
                    }
                }
                let widths = TranscriptTableMetrics.columnWidths(naturals: naturals, available: contentWidth)
                for row in table.cells {
                    for (column, cell) in row.enumerated() where !known(cell, max(widths[column] - TranscriptTableMetrics.padding, 1)) {
                        return false
                    }
                }
            case .rule: break
            }
        }
        return true
    }

    /// Takes a premeasured body into the caches. When main already built the same segments it keeps
    /// them (their identity may be on screen) and the worker's sizes are recorded against them.
    /// False when the body can't be used: built with an older style, or not the shape main built.
    static func adopt(_ body: PremeasuredBody) -> Bool {
        self.syncGeneration()
        guard body.key.styleGeneration == TranscriptStyle.generation else { return false }
        var segments = body.segments
        if let cached = self.segmentCache.value(for: body.key.textKey) {
            guard cached.count == segments.count, zip(cached, segments).allSatisfy({ self.sameKind($0, $1) }) else { return false }
            segments = cached
        } else {
            self.segmentCache.set(segments, for: body.key.textKey)
        }
        for height in body.heights where height.index < segments.count {
            let text: NSAttributedString
            switch segments[height.index] {
            case let .text(string), let .quote(string), let .code(_, _, string): text = string
            case .table, .rule: continue
            }
            self.heightMemo.set((text, CGSize(width: height.usedWidth, height: height.height)),
                                for: MemoKey(object: ObjectIdentifier(text), width: height.width, exact: height.exact))
        }
        for cell in body.cells where cell.index < segments.count {
            guard case let .table(table) = segments[cell.index], cell.row < table.cells.count, cell.column < table.cells[cell.row].count
            else { continue }
            let text = table.cells[cell.row][cell.column]
            self.heightMemo.set((text, CGSize(width: cell.natural, height: 0)), for: MemoKey(object: ObjectIdentifier(text), width: -1, exact: false))
            self.heightMemo.set((text, CGSize(width: cell.usedWidth, height: cell.height)),
                                for: MemoKey(object: ObjectIdentifier(text), width: cell.width, exact: false))
        }
        return true
    }

    private static func sameKind(_ a: Segment, _ b: Segment) -> Bool {
        switch (a, b) {
        case (.text, .text), (.quote, .quote), (.code, .code), (.table, .table), (.rule, .rule): true
        default: false
        }
    }

    /// Drops everything built with an older style (Dynamic Type changed).
    private static func syncGeneration() {
        guard self.cacheGeneration != TranscriptStyle.generation else { return }
        self.segmentCache.removeAll()
        self.heightMemo.removeAll()
        self.cacheGeneration = TranscriptStyle.generation
    }

    /// Number of cached committed-message segment lists, for tests.
    static var segmentCacheCount: Int { self.segmentCache.count }

    // MARK: Building

    static func markdown(_ source: String, tone: Tone, dark: Bool = RichBlock.isDark) -> [Segment] {
        self.syncGeneration()
        let key = Key(source: source, tone: tone, dark: dark)
        if let cached = self.segmentCache.value(for: key) { return cached }
        let segments = self.build(MarkdownCache.blocks(source), tone: tone, env: .current(dark: dark), hooks: .main(cached: true, dark: dark))!
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

    /// What is kept for one streaming row: its frozen text (up to its last cut), the chunks built from it,
    /// and their measured heights.
    private struct LiveState {
        var owner: ObjectIdentifier?
        var tone: Tone
        var generation: Int
        var frozenText = ""
        var chunks: [FrozenChunk] = []
        var heights: [MemoKey: (text: NSAttributedString, height: CGFloat)] = [:]
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
        let env = TextBuildEnvironment.current(dark: RichBlock.isDark)
        var start = source.utf8.index(source.startIndex, offsetBy: state.frozenText.utf8.count)
        for cut in MarkdownBlock.streamingFreezePoints(source, from: start) where cut > start && cut <= source.endIndex {
            let text = String(source[start..<cut])
            start = cut
            let blocks = MarkdownBlock.parse(text)
            var heading = false
            if case .heading = blocks.first { heading = true }
            state.chunks.append(FrozenChunk(segments: self.build(blocks, tone: tone, env: env, hooks: .main(cached: false, dark: env.dark))!, startsWithHeading: heading))
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
            add(self.build(blocks, tone: tone, env: env, hooks: .main(cached: false, dark: env.dark))!, frozen: false, startsWithHeading: heading)
        }
        return result
    }

    /// Size of a live segment's text. Frozen text is measured once per width. Text runs report
    /// their exact height, so many small views add up to what one committed view measures.
    static func liveSize(_ string: NSAttributedString, width: CGFloat, frozen: Bool, exact: Bool) -> CGSize {
        guard frozen else { return self.size(string, width: width, exact: exact) }
        let key = MemoKey(object: ObjectIdentifier(string), width: width, exact: exact)
        if let row = self.heightRow, let known = self.liveStates[row]?.heights[key] { return CGSize(width: width, height: known.height) }
        let size = self.size(string, width: width, exact: exact)
        if let row = self.heightRow { self.liveStates[row]?.heights[key] = (string, size.height) }
        return size
    }

    /// The segments for `blocks`, or nil when `hooks` can't draw inline math and a paragraph has some.
    /// Runs on any thread: it reads only `env` and its arguments.
    nonisolated static func build(_ blocks: [MarkdownBlock], tone: Tone, env: TextBuildEnvironment,
                                  hooks: BuildHooks) -> [Segment]?
    {
        let style = env.fonts
        let color = env.color(for: tone)
        let secondary = env.colors.secondary
        var rejected = false
        var segments: [Segment] = []
        var current = NSMutableAttributedString()

        /// Inline text as attributes on `font`; a paragraph with math the hooks can't draw marks the build rejected.
        func inline(_ text: String, font: PFont, color: PColor) -> NSMutableAttributedString {
            guard let result = self.inline(text, font: font, color: color, fill: env.colors.fill, hooks: hooks) else {
                rejected = true
                return NSMutableAttributedString()
            }
            return result
        }

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
                append(inline(text, font: style.body, color: color), spacingBefore: TranscriptMetrics.blockSpacing)
            case let .heading(level, text):
                let font = level == 1 ? style.title2 : level == 2 ? style.title3 : style.headline
                append(inline(text, font: font, color: color), spacingBefore: TranscriptMetrics.blockSpacing + 2)
            case let .list(items, ordered):
                let markers = items.indices.map { ordered ? "\($0 + 1)." : "•" }
                let markerAttributes: [NSAttributedString.Key: Any] = [.font: style.listMarker, .foregroundColor: secondary]
                let markerWidth = markers.map { ceil(($0 as NSString).size(withAttributes: markerAttributes).width) }.max() ?? 0
                for (index, item) in items.enumerated() {
                    let indent = CGFloat(item.indent) * 14
                    let textStart = indent + markerWidth + 6
                    let line = NSMutableAttributedString(string: markers[index], attributes: markerAttributes)
                    line.append(NSAttributedString(string: "\t", attributes: [.font: style.body]))
                    line.append(inline(item.text, font: style.body, color: color))
                    append(line, spacingBefore: index == 0 ? TranscriptMetrics.blockSpacing : 4) { paragraph in
                        paragraph.firstLineHeadIndent = indent
                        paragraph.headIndent = textStart
                        paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: textStart)]
                        paragraph.defaultTabInterval = 28
                    }
                }
            case let .quote(text):
                flush()
                let quote = inline(text, font: style.body, color: secondary)
                segments.append(.quote(quote))
            case let .code(language, code):
                flush()
                let text = NSAttributedString(string: code, attributes: [.font: style.code, .foregroundColor: env.colors.primary])
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
                        let cell = inline(text, font: font, color: color)
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
        return rejected ? nil : segments
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) as attributes on `font`.
    @MainActor static func inline(_ text: String, font: PFont, color: PColor, cached: Bool = true) -> NSMutableAttributedString {
        self.inline(text, font: font, color: color, fill: TranscriptColors.fill, hooks: .main(cached: cached))!
    }

    /// Nil when the text has inline math and `hooks` can't draw it.
    nonisolated static func inline(_ text: String, font: PFont, color: PColor, fill: PColor,
                                   hooks: BuildHooks) -> NSMutableAttributedString?
    {
        // Inline math is swapped for placeholders before Markdown sees it (so `_` and `*` inside it
        // aren't read as emphasis), then drawn as image attachments.
        let math = InlineMathText.mask(text)
        if !math.spans.isEmpty, hooks.math == nil { return nil }
        let parsed = hooks.parse(math.text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let string = MarkdownBlock.softBreaks(String(parsed[run.range].characters))
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = PFont.monospacedSystemFont(ofSize: (font.pointSize * 0.92).rounded(), weight: .regular)
                    attributes[.backgroundColor] = fill
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
                hooks.math?(string, math.spans, attributes, runFont, color, result)
            }
        }
        return result
    }

    static func plain(_ text: String, font: PFont, color: PColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: Measuring

    /// Size of `string` wrapped to `width` (unwrapped when width is infinite), rounded up to points.
    /// `memoized` remembers the size by the string's identity, for cached segments that are measured
    /// again at the same width; leave it off for strings built for one layout.
    static func size(_ string: NSAttributedString, width: CGFloat, exact: Bool = false, memoized: Bool = false) -> CGSize {
        guard string.length > 0, width > 0 else { return .zero }
        var key: MemoKey?
        if memoized {
            self.syncGeneration()
            let memoKey = MemoKey(object: ObjectIdentifier(string), width: width, exact: exact)
            if let hit = self.heightMemo.value(for: memoKey) {
                self.measureStats.memoHits += 1
                return hit.size
            }
            key = memoKey
        }
        self.measureStats.mainLayouts += 1
        let size = self.measurer.size(string, width: width, exact: exact)
        if let key { self.heightMemo.set((string, size), for: key) }
        return size
    }

    /// Width of `string` on one line, ignoring paragraph alignment. `memoized` is as for `size`.
    static func naturalWidth(_ string: NSAttributedString, memoized: Bool = false) -> CGFloat {
        guard string.length > 0 else { return 0 }
        var key: MemoKey?
        if memoized {
            self.syncGeneration()
            let memoKey = MemoKey(object: ObjectIdentifier(string), width: -1, exact: false)
            if let hit = self.heightMemo.value(for: memoKey) {
                self.measureStats.memoHits += 1
                return hit.size.width
            }
            key = memoKey
        }
        self.measureStats.mainLayouts += 1
        let width = self.measurer.naturalWidth(string)
        if let key { self.heightMemo.set((string, CGSize(width: width, height: 0)), for: key) }
        return width
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
