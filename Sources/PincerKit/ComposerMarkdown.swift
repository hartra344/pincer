import Foundation

/// The kind of a Markdown construct found in composer text.
public enum ComposerMarkdownKind: Equatable, Hashable, Sendable {
    case strong, emphasis, strikethrough, inlineCode
    /// Whole `[text](url)`; markerRanges = `[`, `](`, url, `)`; contentRange = text.
    case link
    /// 1...6; markerRanges = `#… `.
    case heading(Int)
    /// markerRanges = bullet/number/task box including the trailing space.
    case listItem
    /// markerRanges = `>` plus a space.
    case blockquote
    /// A ``` or ~~~ line (opening or closing); the whole line is marker.
    case codeFence
    /// A content line inside a fence, or an indented (4+ columns) code line.
    case codeBlock
}

/// One styled construct. All ranges are UTF-16, in absolute document coordinates.
public struct ComposerMarkdownSpan: Equatable, Hashable, Sendable {
    public var kind: ComposerMarkdownKind
    /// Full extent including markers.
    public var range: NSRange
    /// The styled text without markers.
    public var contentRange: NSRange
    /// Ranges to dim.
    public var markerRanges: [NSRange]

    public init(kind: ComposerMarkdownKind, range: NSRange, contentRange: NSRange, markerRanges: [NSRange]) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.markerRanges = markerRanges
    }
}

/// Pragmatic CommonMark-subset tokenizer working on UTF-16 buffers. Pure and thread-safe.
public enum ComposerMarkdown {
    /// Whole-document tokenize. O(n). Safe off main.
    public static func tokenize(_ text: String) -> [ComposerMarkdownSpan] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        return withBuffer(ns, NSRange(location: 0, length: length)) { p in
            var scanner = MarkdownScanner(p: p, base: 0)
            scanner.scanLines(start: 0, end: length, open: nil, indent: MarkdownIndentState())
            return scanner.out
        }
    }

    /// The paragraph-aligned range covering `editedRange` (NSString line-range semantics).
    public static func paragraphRange(in text: NSString, covering editedRange: NSRange) -> NSRange {
        let length = text.length
        let location = min(max(editedRange.location, 0), length)
        let upper = min(max(NSMaxRange(editedRange), location), length)
        return text.lineRange(for: NSRange(location: location, length: upper - location))
    }

    /// True when hardware Return should insert a newline instead of sending: the caret is on an opening
    /// fence line or inside a fenced block (an unclosed fence counts to the end). False on the closing
    /// fence line and outside blocks. O(n); only call on Return.
    public static func returnInsertsNewline(in text: NSString, at location: Int) -> Bool {
        let length = text.length
        guard length > 0 else { return false }
        let loc = min(max(location, 0), length)
        let line = text.lineRange(for: NSRange(location: loc, length: 0))
        let index = ComposerMarkdownIndex(text: text)
        var before = 0
        var onFence = false
        for f in index.fences {
            if f.location < line.location { before += 1 } else {
                onFence = f.location == line.location
                break
            }
        }
        if onFence { return before & 1 == 0 }
        return before & 1 == 1
    }

    static func withBuffer<R>(_ text: NSString, _ range: NSRange, _ body: (UnsafePointer<unichar>) -> R) -> R {
        if range.length == 0 {
            var zero: unichar = 0
            return withUnsafePointer(to: &zero) { body($0) }
        }
        let buffer = [unichar](unsafeUninitializedCapacity: range.length) { buf, count in
            text.getCharacters(buf.baseAddress!, range: range)
            count = range.length
        }
        return buffer.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

// MARK: Incremental index

/// Fence state for incremental restyling. Value type; `update` is O(edited paragraphs) plus an O(fences)
/// offset shift and re-pairing on ordinary keystrokes.
public struct ComposerMarkdownIndex: Sendable {
    /// Every ``` / ~~~ line in order, whether or not it pairs.
    var candidates: [MarkdownFence]
    /// The fence lines that open or close a block, in order: opening, closing, opening…
    var fences: [MarkdownFence]
    var length: Int

    /// O(n); run off main for big text.
    public init(text: NSString) {
        let length = text.length
        self.length = length
        self.candidates = length == 0 ? [] : ComposerMarkdown.withBuffer(text, NSRange(location: 0, length: length)) { p in
            MarkdownScanner.fenceLines(p, 0, length, base: 0)
        }
        self.fences = Self.pair(self.candidates)
    }

    /// Call after every text-storage edit (`editedRange` in the NEW text, `changeInLength` delta).
    /// Returns the range of NEW text whose styling must be recomputed: the edited paragraph(s), extended
    /// to the end of the document when fence state changed, or over the following blank and indented lines
    /// when the edit may change which of them are indented code.
    public mutating func update(text: NSString, editedRange: NSRange, changeInLength: Int) -> NSRange {
        let len = text.length
        let loc = editedRange.location
        let upper = NSMaxRange(editedRange)
        guard self.length + changeInLength == len, loc >= 0, editedRange.length >= 0, upper <= len else {
            self = ComposerMarkdownIndex(text: text)
            return NSRange(location: 0, length: len)
        }
        let a = text.lineRange(for: NSRange(location: loc, length: 0))
        let b = text.lineRange(for: NSRange(location: upper, length: 0))
        let pEnd = max(NSMaxRange(a), NSMaxRange(b))
        let paragraph = NSRange(location: a.location, length: pEnd - a.location)
        let oldEnd = pEnd - changeInLength
        guard oldEnd >= paragraph.location else {
            self = ComposerMarkdownIndex(text: text)
            return NSRange(location: 0, length: len)
        }

        let oldOpen = self.openFence(before: oldEnd)
        let lo = Self.lowerBound(self.candidates, paragraph.location)
        let hi = Self.lowerBound(self.candidates, oldEnd)
        if changeInLength != 0, hi < self.candidates.count {
            for k in hi..<self.candidates.count { self.candidates[k].range.location += changeInLength }
        }
        let fresh: [MarkdownFence] = paragraph.length == 0 ? [] : ComposerMarkdown.withBuffer(text, paragraph) { p in
            MarkdownScanner.fenceLines(p, 0, paragraph.length, base: paragraph.location)
        }
        if hi > lo || !fresh.isEmpty { self.candidates.replaceSubrange(lo..<hi, with: fresh) }
        self.fences = Self.pair(self.candidates)
        self.length = len

        let newOpen = self.openFence(before: pEnd)
        if oldOpen?.marker != newOpen?.marker || oldOpen?.count != newOpen?.count {
            return NSRange(location: paragraph.location, length: len - paragraph.location)
        }
        guard newOpen == nil, !Self.isIndentedInsertion(text, editedRange: editedRange, changeInLength: changeInLength, line: a)
        else { return paragraph }
        var end = pEnd
        while end < len {
            let line = text.lineRange(for: NSRange(location: end, length: 0))
            guard Self.isBlankOrIndented(text, line) else { break }
            end = NSMaxRange(line)
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }

    /// Spans inside `range` (paragraph-aligned), honouring fence and indented-code state. O(|range|) plus a walk
    /// back over any blank or indented lines just above it.
    public func spans(in text: NSString, range: NSRange) -> [ComposerMarkdownSpan] {
        let len = text.length
        guard len > 0 else { return [] }
        let clamped = NSRange(location: min(max(range.location, 0), len), length: 0)
        let upper = min(max(NSMaxRange(range), clamped.location), len)
        let aligned = text.lineRange(for: NSRange(location: clamped.location, length: upper - clamped.location))
        guard aligned.length > 0 else { return [] }
        let open = self.openFence(before: aligned.location)
        let indent = open == nil ? self.indentState(in: text, before: aligned.location) : MarkdownIndentState()
        return ComposerMarkdown.withBuffer(text, aligned) { p in
            var scanner = MarkdownScanner(p: p, base: aligned.location)
            scanner.scanLines(start: 0, end: aligned.length, open: open, indent: indent)
            return scanner.out
        }
    }

    /// True for fence lines and the lines between an opening and its closing fence (or the end of the text).
    public func isInsideCodeBlock(_ location: Int) -> Bool {
        let k = Self.lowerBound(self.fences, location + 1)
        if k == 0 { return false }
        if k & 1 == 1 { return true }
        return location <= NSMaxRange(self.fences[k - 1].range)
    }

    /// `isInsideCodeBlock(_:)`, plus indented code blocks.
    public func isInsideCodeBlock(_ location: Int, in text: NSString) -> Bool {
        if self.isInsideCodeBlock(location) { return true }
        let length = text.length
        guard length > 0 else { return false }
        let line = text.lineRange(for: NSRange(location: min(max(location, 0), length), length: 0))
        guard line.length > 0 else { return false }
        var state = self.indentState(in: text, before: line.location)
        return ComposerMarkdown.withBuffer(text, line) { p in
            let end = MarkdownScanner.lineBounds(p, 0, line.length).lineEnd
            return MarkdownScanner.step(&state, p, 0, end)
        }
    }

    /// The fence a line starting at `location` would be inside, or nil.
    private func openFence(before location: Int) -> MarkdownFence? {
        let k = Self.lowerBound(self.fences, location)
        return k & 1 == 1 ? self.fences[k - 1] : nil
    }

    /// Indented-code state just before the line at `location` (outside fences): replays from the nearest line
    /// above that isn't blank or indented.
    private func indentState(in text: NSString, before location: Int) -> MarkdownIndentState {
        var anchor = 0
        var found = false
        var pos = location
        while pos > 0 {
            let line = text.lineRange(for: NSRange(location: pos - 1, length: 0))
            pos = line.location
            if !Self.isBlankOrIndented(text, line) {
                anchor = line.location
                found = true
                break
            }
        }
        guard location > anchor else { return MarkdownIndentState() }
        let anchorIsFence = found && self.fences.contains { $0.location == anchor }
        return ComposerMarkdown.withBuffer(text, NSRange(location: anchor, length: location - anchor)) { p in
            var state = MarkdownIndentState()
            var i = 0
            let end = location - anchor
            while i < end {
                let (le, next) = MarkdownScanner.lineBounds(p, i, end)
                if i == 0, anchorIsFence { state = .afterFence } else { _ = MarkdownScanner.step(&state, p, i, le) }
                i = next
            }
            return state
        }
    }

    /// Typing (no line break) after the first non-blank character of an indented line can't change which lines
    /// below are indented code, so the restyle can stay on that line.
    private static func isIndentedInsertion(_ text: NSString, editedRange: NSRange, changeInLength: Int, line: NSRange) -> Bool {
        guard changeInLength == editedRange.length, editedRange.length > 0 else { return false }
        for k in editedRange.location..<NSMaxRange(editedRange) where mdIsLineBreak(text.character(at: k)) { return false }
        var columns = 0
        var k = line.location
        while k < editedRange.location {
            let c = text.character(at: k)
            if c == 32 { columns += 1 } else if c == 9 { columns += 4 } else { break }
            k += 1
        }
        return columns >= 4 && k < editedRange.location
    }

    /// Blank, or indented 4+ columns.
    static func isBlankOrIndented(_ text: NSString, _ line: NSRange) -> Bool {
        var columns = 0
        var k = line.location
        let end = NSMaxRange(line)
        while k < end {
            let c = text.character(at: k)
            if c == 32 { columns += 1 } else if c == 9 { columns += 4 } else { return mdIsLineBreak(c) || columns >= 4 }
            if columns >= 4 { return true }
            k += 1
        }
        return true
    }

    /// Pairs candidates the CommonMark way: a block closes on a bare fence of the same character, at least as long.
    static func pair(_ candidates: [MarkdownFence]) -> [MarkdownFence] {
        var out: [MarkdownFence] = []
        var open: MarkdownFence?
        for fence in candidates {
            if let o = open {
                if o.isClosed(by: fence) {
                    out.append(fence)
                    open = nil
                }
            } else {
                out.append(fence)
                open = fence
            }
        }
        return out
    }

    /// First index whose location is >= `value`.
    private static func lowerBound(_ fences: [MarkdownFence], _ value: Int) -> Int {
        var lo = 0
        var hi = fences.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if fences[mid].location < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// A ``` or ~~~ line (3+ markers after at most 3 spaces).
struct MarkdownFence: Equatable, Sendable {
    /// The line, excluding its terminator.
    var range: NSRange
    /// 96 (`) or 126 (~).
    var marker: unichar
    var count: Int
    /// Nothing but spaces or tabs after the markers, so it can close a block.
    var isBare: Bool
    var location: Int { range.location }

    func isClosed(by other: MarkdownFence) -> Bool {
        other.marker == self.marker && other.count >= self.count && other.isBare
    }
}

/// What an indented (4+ columns) line means, given the lines above it (outside fences).
struct MarkdownIndentState: Equatable, Sendable {
    /// The last unindented line allows a code block after a blank line (not a list item or indented text).
    var anchorAllows = true
    /// A blank line (or the start of the text, or a closing fence) came after that line.
    var blankSince = true
    /// Inside an indented code block (blank lines don't end it).
    var inCode = false

    static let afterFence = MarkdownIndentState()
}

// MARK: Scanner

@inline(__always) func mdIsLineBreak(_ c: unichar) -> Bool {
    c == 10 || c == 13 || c == 0x2028 || c == 0x2029 || c == 0x85
}

@inline(__always) func mdIsWhitespace(_ c: unichar) -> Bool {
    c == 32 || c == 9 || c == 0xA0 || mdIsLineBreak(c)
}

@inline(__always) func mdIsAlnum(_ c: unichar) -> Bool {
    if c < 0x80 { return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    return !mdIsWhitespace(c) && !(c >= 0x2000 && c <= 0x206F)
}

struct MarkdownScanner {
    let p: UnsafePointer<unichar>
    let base: Int
    var out: [ComposerMarkdownSpan] = []

    init(p: UnsafePointer<unichar>, base: Int) {
        self.p = p
        self.base = base
    }

    /// Index of the line terminator at or after `i` (or `end`), and the index of the next line.
    @inline(__always)
    static func lineBounds(_ p: UnsafePointer<unichar>, _ i: Int, _ end: Int) -> (lineEnd: Int, next: Int) {
        var t = i
        while t < end, !mdIsLineBreak(p[t]) { t += 1 }
        var next = t
        if t < end {
            next = t + 1
            if p[t] == 13, next < end, p[next] == 10 { next += 1 }
        }
        return (t, next)
    }

    /// The fence on line [s, e), if it is one.
    static func fence(_ p: UnsafePointer<unichar>, _ s: Int, _ e: Int, base: Int) -> MarkdownFence? {
        var i = s
        while i < e, p[i] == 32 { i += 1 }
        guard i - s <= 3, i < e, p[i] == 96 || p[i] == 126 else { return nil }
        let marker = p[i]
        var n = 0
        while i < e, p[i] == marker { i += 1; n += 1 }
        guard n >= 3 else { return nil }
        var bare = true
        while i < e {
            // A backtick fence's info string can't hold a backtick (it would be inline code).
            if marker == 96, p[i] == 96 { return nil }
            if p[i] != 32, p[i] != 9 { bare = false }
            i += 1
        }
        return MarkdownFence(range: NSRange(location: base + s, length: e - s), marker: marker, count: n, isBare: bare)
    }

    static func fenceLines(_ p: UnsafePointer<unichar>, _ start: Int, _ end: Int, base: Int) -> [MarkdownFence] {
        var result: [MarkdownFence] = []
        var i = start
        while i < end {
            let (le, next) = lineBounds(p, i, end)
            if le - i >= 3, let fence = fence(p, i, le, base: base) { result.append(fence) }
            i = next
        }
        return result
    }

    /// Advances `state` past line [s, e) (outside fences); true when that line is indented code. Conservative:
    /// a 4+ column line is code only after a blank line (or at the start, or after a closing fence) and never
    /// under a list item or indented text, where it's more likely list content.
    static func step(_ state: inout MarkdownIndentState, _ p: UnsafePointer<unichar>, _ s: Int, _ e: Int) -> Bool {
        var columns = 0
        var i = s
        while i < e, p[i] == 32 || p[i] == 9 {
            columns += p[i] == 9 ? 4 : 1
            i += 1
        }
        if i == e {
            state.blankSince = true
            return false
        }
        if columns >= 4 {
            guard state.inCode || (state.anchorAllows && state.blankSince) else { return false }
            state.inCode = true
            return true
        }
        state.inCode = false
        state.blankSince = false
        state.anchorAllows = columns == 0 && listMarkerEnd(p, i, e) == nil
        return false
    }

    mutating func scanLines(start: Int, end: Int, open startOpen: MarkdownFence?, indent: MarkdownIndentState) {
        var open = startOpen
        var indent = indent
        var i = start
        while i < end {
            let (le, next) = Self.lineBounds(p, i, end)
            let fence = le - i >= 3 ? Self.fence(p, i, le, base: base) : nil
            if let fence, open == nil || open!.isClosed(by: fence) {
                out.append(ComposerMarkdownSpan(
                    kind: .codeFence, range: fence.range,
                    contentRange: NSRange(location: base + le, length: 0), markerRanges: [fence.range]))
                if open == nil {
                    open = fence
                } else {
                    open = nil
                    indent = .afterFence
                }
            } else if open != nil || Self.step(&indent, p, i, le) {
                if le > i {
                    let r = NSRange(location: base + i, length: le - i)
                    out.append(ComposerMarkdownSpan(kind: .codeBlock, range: r, contentRange: r, markerRanges: []))
                }
            } else if le > i {
                scanLine(i, le)
            }
            i = next
        }
    }

    @inline(__always)
    private func nsr(_ a: Int, _ b: Int) -> NSRange { NSRange(location: base + a, length: b - a) }

    private mutating func scanLine(_ s: Int, _ e: Int) {
        var i = s
        while i < e, p[i] == 32 || p[i] == 9 { i += 1 }
        // Block quotes (possibly nested).
        while i < e, p[i] == 62 {
            var m = i + 1
            if m < e, p[m] == 32 { m += 1 }
            out.append(ComposerMarkdownSpan(
                kind: .blockquote, range: nsr(i, e), contentRange: nsr(m, e), markerRanges: [nsr(i, m)]))
            i = m
        }
        var j = i
        while j < e, p[j] == 32 || p[j] == 9 { j += 1 }
        guard j < e else { return }

        let c = p[j]
        if c == 35 {
            var n = 0
            while j + n < e, p[j + n] == 35 { n += 1 }
            if n <= 6, j + n == e || p[j + n] == 32 || p[j + n] == 9 {
                let me = j + n + (j + n < e ? 1 : 0)
                out.append(ComposerMarkdownSpan(
                    kind: .heading(n), range: nsr(j, e), contentRange: nsr(me, e), markerRanges: [nsr(j, me)]))
                scan(me, e)
                return
            }
        }
        if let markerEnd = Self.listMarkerEnd(p, j, e) {
            out.append(ComposerMarkdownSpan(
                kind: .listItem, range: nsr(j, e), contentRange: nsr(markerEnd, e), markerRanges: [nsr(j, markerEnd)]))
            scan(markerEnd, e)
            return
        }
        scan(i, e)
    }

    /// End (exclusive) of a list marker (bullet or number, one trailing space, optional task box) starting at `j`.
    static func listMarkerEnd(_ p: UnsafePointer<unichar>, _ j: Int, _ e: Int) -> Int? {
        var k = j
        let c = p[k]
        if c == 45 || c == 42 || c == 43 {
            k += 1
        } else if c >= 48, c <= 57 {
            var digits = 0
            while k < e, p[k] >= 48, p[k] <= 57, digits < 10 { k += 1; digits += 1 }
            guard digits <= 9, k < e, p[k] == 46 || p[k] == 41 else { return nil }
            k += 1
        } else {
            return nil
        }
        guard k < e, p[k] == 32 || p[k] == 9 else { return nil }
        var m = k + 1
        if m + 2 < e, p[m] == 91, p[m + 1] == 32 || p[m + 1] == 120 || p[m + 1] == 88, p[m + 2] == 93,
           m + 3 == e || p[m + 3] == 32 || p[m + 3] == 9 {
            m += m + 3 < e ? 4 : 3
        }
        return m
    }

    // MARK: Inline

    /// Scans inline constructs in `[s, e)`.
    mutating func scan(_ s: Int, _ e: Int) {
        var failed = 0
        var i = s
        while i < e {
            let c = p[i]
            switch c {
            case 92:
                i += 2
            case 96:
                var j = i
                while j < e, p[j] == 96 { j += 1 }
                let n = j - i
                if let close = findBacktickClose(j, e, n) {
                    out.append(ComposerMarkdownSpan(
                        kind: .inlineCode, range: nsr(i, close + n), contentRange: nsr(j, close),
                        markerRanges: [nsr(i, j), nsr(close, close + n)]))
                    i = close + n
                } else {
                    i = j
                }
            case 91:
                i = tryLink(i, e) ?? i + 1
            case 42, 95, 126:
                var j = i
                while j < e, p[j] == c { j += 1 }
                i = tryEmphasis(c, s, i, j, e, &failed) ?? j
            default:
                i += 1
            }
        }
    }

    private func findBacktickClose(_ from: Int, _ e: Int, _ n: Int) -> Int? {
        var k = from
        while k < e {
            if p[k] == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if m - k == n { return k }
                k = m
            } else {
                k += 1
            }
        }
        return nil
    }

    private mutating func tryLink(_ i: Int, _ e: Int) -> Int? {
        var depth = 1
        var k = i + 1
        while k < e {
            let c = p[k]
            if c == 92 {
                k += 2
                continue
            }
            if c == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if let close = findBacktickClose(m, e, m - k) { k = close + (m - k) } else { k = m }
                continue
            }
            if c == 91 {
                depth += 1
            } else if c == 93 {
                depth -= 1
                if depth == 0 { break }
            }
            k += 1
        }
        guard depth == 0, k + 1 < e, p[k + 1] == 40 else { return nil }
        let cb = k
        var m = cb + 2
        var pd = 1
        while m < e {
            let c = p[m]
            if c == 92 {
                m += 2
                continue
            }
            if c == 40 {
                pd += 1
            } else if c == 41 {
                pd -= 1
                if pd == 0 { break }
            }
            m += 1
        }
        guard pd == 0, m < e else { return nil }
        var markers = [nsr(i, i + 1), nsr(cb, cb + 2)]
        if m > cb + 2 { markers.append(nsr(cb + 2, m)) }
        markers.append(nsr(m, m + 1))
        out.append(ComposerMarkdownSpan(
            kind: .link, range: nsr(i, m + 1), contentRange: nsr(i + 1, cb), markerRanges: markers))
        if cb > i + 1 { scan(i + 1, cb) }
        return m + 1
    }

    private mutating func tryEmphasis(_ c: unichar, _ lower: Int, _ i: Int, _ j: Int, _ e: Int, _ failed: inout Int) -> Int? {
        let n = j - i
        if c == 126 {
            guard n == 2 else { return nil }
        } else {
            guard n <= 3 else { return nil }
        }
        guard j < e, !mdIsWhitespace(p[j]) else { return nil }
        if c == 95, i > lower, mdIsAlnum(p[i - 1]) { return nil }
        let kind = c == 42 ? 0 : (c == 95 ? 1 : 2)
        let bit = 1 << (kind * 4 + n)
        if failed & bit != 0 { return nil }

        var k = j
        var closer = -1
        while k < e {
            let ch = p[k]
            if ch == 92 {
                k += 2
            } else if ch == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if let close = findBacktickClose(m, e, m - k) { k = close + (m - k) } else { k = m }
            } else if ch == c {
                var m = k
                while m < e, p[m] == c { m += 1 }
                if m - k == n, k > j, !mdIsWhitespace(p[k - 1]), c != 95 || m >= e || !mdIsAlnum(p[m]) {
                    closer = k
                    break
                }
                k = m
            } else {
                k += 1
            }
        }
        guard closer >= 0 else {
            failed |= bit
            return nil
        }
        let k2 = closer
        switch n {
        case 1:
            out.append(ComposerMarkdownSpan(
                kind: .emphasis, range: nsr(i, k2 + 1), contentRange: nsr(i + 1, k2),
                markerRanges: [nsr(i, i + 1), nsr(k2, k2 + 1)]))
        case 2:
            out.append(ComposerMarkdownSpan(
                kind: c == 126 ? .strikethrough : .strong, range: nsr(i, k2 + 2), contentRange: nsr(i + 2, k2),
                markerRanges: [nsr(i, i + 2), nsr(k2, k2 + 2)]))
        default:
            out.append(ComposerMarkdownSpan(
                kind: .emphasis, range: nsr(i, k2 + 3), contentRange: nsr(i + 1, k2 + 2),
                markerRanges: [nsr(i, i + 1), nsr(k2 + 2, k2 + 3)]))
            out.append(ComposerMarkdownSpan(
                kind: .strong, range: nsr(i + 1, k2 + 2), contentRange: nsr(i + 3, k2),
                markerRanges: [nsr(i + 1, i + 3), nsr(k2, k2 + 2)]))
        }
        scan(i + n, k2)
        return k2 + n
    }
}
