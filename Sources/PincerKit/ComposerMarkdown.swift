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
    /// A ``` line (opening or closing); the whole line is marker.
    case codeFence
    /// A content line inside a fence.
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
            scanner.scanLines(start: 0, end: length, inside: false)
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

/// Fence state for incremental restyling. Value type; `update` is O(edited paragraphs + log fences)
/// plus an O(fences) offset shift on ordinary keystrokes.
public struct ComposerMarkdownIndex: Sendable {
    /// Sorted line ranges (excluding the terminator) of every ``` line.
    var fences: [NSRange]
    var length: Int

    /// O(n); run off main for big text.
    public init(text: NSString) {
        let length = text.length
        self.length = length
        self.fences = length == 0 ? [] : ComposerMarkdown.withBuffer(text, NSRange(location: 0, length: length)) { p in
            MarkdownScanner.fenceLines(p, 0, length, base: 0)
        }
    }

    /// Call after every text-storage edit (`editedRange` in the NEW text, `changeInLength` delta).
    /// Returns the range of NEW text whose styling must be recomputed: the edited paragraph(s), extended
    /// to the end of the document when fence membership changed.
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

        let lo = self.lowerBound(paragraph.location)
        let hi = self.lowerBound(oldEnd)
        if changeInLength != 0, hi < self.fences.count {
            for k in hi..<self.fences.count { self.fences[k].location += changeInLength }
        }
        let fresh: [NSRange] = paragraph.length == 0 ? [] : ComposerMarkdown.withBuffer(text, paragraph) { p in
            MarkdownScanner.fenceLines(p, 0, paragraph.length, base: paragraph.location)
        }
        let removed = hi - lo
        if removed != 0 || !fresh.isEmpty { self.fences.replaceSubrange(lo..<hi, with: fresh) }
        self.length = len

        if (fresh.count - removed) & 1 != 0 {
            return NSRange(location: paragraph.location, length: len - paragraph.location)
        }
        return paragraph
    }

    /// Spans inside `range` (paragraph-aligned), honouring fence state. O(|range|).
    public func spans(in text: NSString, range: NSRange) -> [ComposerMarkdownSpan] {
        let len = text.length
        guard len > 0 else { return [] }
        let clamped = NSRange(location: min(max(range.location, 0), len), length: 0)
        let upper = min(max(NSMaxRange(range), clamped.location), len)
        let aligned = text.lineRange(for: NSRange(location: clamped.location, length: upper - clamped.location))
        guard aligned.length > 0 else { return [] }
        let inside = self.lowerBound(aligned.location) & 1 == 1
        return ComposerMarkdown.withBuffer(text, aligned) { p in
            var scanner = MarkdownScanner(p: p, base: aligned.location)
            scanner.scanLines(start: 0, end: aligned.length, inside: inside)
            return scanner.out
        }
    }

    /// True for fence lines and the lines between an opening and its closing fence (or the end of the text).
    public func isInsideCodeBlock(_ location: Int) -> Bool {
        let k = self.lowerBound(location + 1)
        if k == 0 { return false }
        if k & 1 == 1 { return true }
        let last = self.fences[k - 1]
        return location <= NSMaxRange(last)
    }

    /// First index whose location is >= `value`.
    private func lowerBound(_ value: Int) -> Int {
        var lo = 0
        var hi = self.fences.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if self.fences[mid].location < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
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

    static func isFenceLine(_ p: UnsafePointer<unichar>, _ s: Int, _ e: Int) -> Bool {
        var i = s
        while i < e, p[i] == 32 { i += 1 }
        if i - s > 3 { return false }
        var n = 0
        while i < e, p[i] == 96 { i += 1; n += 1 }
        if n < 3 { return false }
        while i < e {
            if p[i] == 96 { return false }
            i += 1
        }
        return true
    }

    static func fenceLines(_ p: UnsafePointer<unichar>, _ start: Int, _ end: Int, base: Int) -> [NSRange] {
        var result: [NSRange] = []
        var i = start
        while i < end {
            let (le, next) = lineBounds(p, i, end)
            if le - i >= 3, isFenceLine(p, i, le) {
                result.append(NSRange(location: base + i, length: le - i))
            }
            i = next
        }
        return result
    }

    mutating func scanLines(start: Int, end: Int, inside startInside: Bool) {
        var inside = startInside
        var i = start
        while i < end {
            let (le, next) = Self.lineBounds(p, i, end)
            if le - i >= 3, Self.isFenceLine(p, i, le) {
                let r = NSRange(location: base + i, length: le - i)
                out.append(ComposerMarkdownSpan(
                    kind: .codeFence, range: r,
                    contentRange: NSRange(location: base + le, length: 0), markerRanges: [r]))
                inside.toggle()
            } else if inside {
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
