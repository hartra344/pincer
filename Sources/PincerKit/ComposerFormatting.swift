import Foundation

/// A text replacement the composer applies through the text system (so undo keeps working).
public struct ComposerEdit: Equatable, Sendable {
    /// Range in the CURRENT text to replace.
    public var range: NSRange
    public var replacement: String
    /// Selection in the text AFTER applying the edit.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum ComposerInlineStyle: CaseIterable, Sendable { case bold, italic, strikethrough, inlineCode }

/// Pure Markdown editing commands for the composer. All ranges are UTF-16.
public enum ComposerFormatting {
    // MARK: Inline styles

    /// Wraps or unwraps the selection (or the caret) with the style's marker.
    public static func toggle(_ style: ComposerInlineStyle, in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let markers = markers(for: style)
        if sel.length == 0 { return toggleAtCaret(markers, text, sel.location) }

        let selected = text.substring(with: sel)
        if selected.contains(where: { $0.isNewline }) {
            return toggleMultiline(markers, text, sel)
        }
        let s = selected as NSString
        var lead = 0
        while lead < s.length, isBlank(s.character(at: lead)) { lead += 1 }
        var trail = 0
        while trail < s.length - lead, isBlank(s.character(at: s.length - 1 - trail)) { trail += 1 }
        if lead + trail >= s.length { lead = 0; trail = 0 }
        let core = NSRange(location: sel.location + lead, length: s.length - lead - trail)
        let coreStr = text.substring(with: core)

        for m in markers {
            if let inner = unwrapped(coreStr, m) {
                return ComposerEdit(
                    range: core, replacement: inner,
                    selection: NSRange(location: core.location, length: (inner as NSString).length))
            }
        }
        let ml = (markers[0] as NSString).length
        for m in markers where outsideWrapped(text, core, m) {
            let l = (m as NSString).length
            return ComposerEdit(
                range: NSRange(location: core.location - l, length: core.length + 2 * l),
                replacement: coreStr,
                selection: NSRange(location: core.location - l, length: core.length))
        }
        return ComposerEdit(
            range: core, replacement: markers[0] + coreStr + markers[0],
            selection: NSRange(location: core.location + ml, length: core.length))
    }

    private static func markers(for style: ComposerInlineStyle) -> [String] {
        switch style {
        case .bold: ["**", "__"]
        case .italic: ["_", "*"]
        case .strikethrough: ["~~"]
        case .inlineCode: ["`"]
        }
    }

    private static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// `core` minus its own surrounding markers, when it is wrapped.
    private static func unwrapped(_ core: String, _ m: String) -> String? {
        let ns = core as NSString
        let l = (m as NSString).length
        guard ns.length > 2 * l, core.hasPrefix(m), core.hasSuffix(m) else { return nil }
        let inner = ns.substring(with: NSRange(location: l, length: ns.length - 2 * l))
        if l == 1, let f = m.utf16.first {
            let i = inner as NSString
            if i.character(at: 0) == f || i.character(at: i.length - 1) == f { return nil }
        }
        return inner
    }

    private static func outsideWrapped(_ text: NSString, _ core: NSRange, _ m: String) -> Bool {
        let l = (m as NSString).length
        guard core.location >= l, NSMaxRange(core) + l <= text.length else { return false }
        guard text.substring(with: NSRange(location: core.location - l, length: l)) == m,
              text.substring(with: NSRange(location: NSMaxRange(core), length: l)) == m else { return false }
        if l == 1, let f = m.utf16.first {
            if core.location >= 2, text.character(at: core.location - 2) == f { return false }
            if NSMaxRange(core) + 1 < text.length, text.character(at: NSMaxRange(core) + 1) == f { return false }
        }
        return true
    }

    private static func toggleAtCaret(_ markers: [String], _ text: NSString, _ c: Int) -> ComposerEdit {
        for m in markers {
            let l = (m as NSString).length
            guard c >= l, c + l <= text.length,
                  text.substring(with: NSRange(location: c - l, length: l)) == m,
                  text.substring(with: NSRange(location: c, length: l)) == m else { continue }
            if l == 1, let f = m.utf16.first {
                if c >= 2, text.character(at: c - 2) == f { continue }
                if c + 1 < text.length, text.character(at: c + 1) == f { continue }
            }
            return ComposerEdit(
                range: NSRange(location: c - l, length: 2 * l), replacement: "",
                selection: NSRange(location: c - l, length: 0))
        }
        let m = markers[0]
        return ComposerEdit(
            range: NSRange(location: c, length: 0), replacement: m + m,
            selection: NSRange(location: c + (m as NSString).length, length: 0))
    }

    /// Per-line wrapping: inline Markdown never spans lines.
    private static func toggleMultiline(_ markers: [String], _ text: NSString, _ sel: NSRange) -> ComposerEdit {
        struct Piece { var prefix: String; var core: String; var suffix: String; var terminator: String }
        var pieces: [Piece] = []
        var pos = sel.location
        while pos < NSMaxRange(sel) {
            let lr = text.lineRange(for: NSRange(location: pos, length: 0))
            let end = min(NSMaxRange(lr), NSMaxRange(sel))
            var contentEnd = end
            while contentEnd > pos, isBreak(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
            var start = pos
            if pos == lr.location {
                start = max(pos, min(contentStart(text, lr), contentEnd))
            }
            var a = start
            while a < contentEnd, isBlank(text.character(at: a)) { a += 1 }
            var b = contentEnd
            while b > a, isBlank(text.character(at: b - 1)) { b -= 1 }
            pieces.append(Piece(
                prefix: text.substring(with: NSRange(location: pos, length: a - pos)),
                core: text.substring(with: NSRange(location: a, length: b - a)),
                suffix: text.substring(with: NSRange(location: b, length: contentEnd - b)),
                terminator: text.substring(with: NSRange(location: contentEnd, length: end - contentEnd))))
            pos = end
        }
        let marked = pieces.filter { !$0.core.isEmpty }
        let allWrapped = !marked.isEmpty && marked.allSatisfy { piece in markers.contains { unwrapped(piece.core, $0) != nil } }
        var result = ""
        for piece in pieces {
            var core = piece.core
            if !core.isEmpty {
                if allWrapped {
                    for m in markers { if let inner = unwrapped(core, m) { core = inner; break } }
                } else {
                    core = markers[0] + core + markers[0]
                }
            }
            result += piece.prefix + core + piece.suffix + piece.terminator
        }
        return ComposerEdit(
            range: sel, replacement: result,
            selection: NSRange(location: sel.location, length: (result as NSString).length))
    }

    // MARK: Links

    /// Selection `foo` → `[foo](url)` with `url` selected; inside `[text](url)` → `text`.
    public static func toggleLink(in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let line = text.lineRange(for: NSRange(location: sel.location, length: 0))
        if NSMaxRange(sel) <= NSMaxRange(line) {
            let lineText = text.substring(with: line)
            for span in ComposerMarkdown.tokenize(lineText) where span.kind == .link {
                let r = NSRange(location: span.range.location + line.location, length: span.range.length)
                if r.location <= sel.location, NSMaxRange(sel) <= NSMaxRange(r) {
                    let content = (lineText as NSString).substring(with: span.contentRange)
                    return ComposerEdit(
                        range: r, replacement: content,
                        selection: NSRange(location: r.location, length: (content as NSString).length))
                }
            }
        }
        if sel.length == 0 {
            return ComposerEdit(
                range: sel, replacement: "[](url)",
                selection: NSRange(location: sel.location + 1, length: 0))
        }
        let selected = text.substring(with: sel)
        if looksLikeURL(selected) {
            return ComposerEdit(
                range: sel, replacement: "[](\(selected))",
                selection: NSRange(location: sel.location + 1, length: 0))
        }
        let urlStart = sel.location + 1 + sel.length + 2
        return ComposerEdit(
            range: sel, replacement: "[\(selected)](url)",
            selection: NSRange(location: urlStart, length: 3))
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return (t.hasPrefix("http://") || t.hasPrefix("https://")) && !t.contains(where: { $0.isWhitespace })
    }

    // MARK: Lists

    /// Toggles `- ` on every line the selection touches.
    public static func toggleList(in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let lines = touchedLines(text, sel)
        let prefixes = lines.map { parsePrefix(text, $0) }
        let nonBlank = zip(lines, prefixes).filter { !isBlankLine(text, $0.1) }
        let allList = !nonBlank.isEmpty && nonBlank.allSatisfy { $0.1.isList }
        var edits: [PartialEdit] = []
        if allList {
            for (_, p) in nonBlank {
                edits.append(PartialEdit(loc: p.markerStart, removeLen: p.markerEnd - p.markerStart, insert: ""))
            }
        } else {
            let targets = nonBlank.isEmpty ? Array(zip(lines, prefixes)) : nonBlank
            for (_, p) in targets where !p.isList {
                let point = p.isQuote ? p.quoteEnd : p.indentEnd
                edits.append(PartialEdit(loc: point, removeLen: 0, insert: "- "))
            }
        }
        guard !edits.isEmpty else {
            return ComposerEdit(range: NSRange(location: sel.location, length: 0), replacement: "", selection: sel)
        }
        return compose(edits, text, sel)
    }

    // MARK: Smart newline

    /// Continues a list item or quote. nil → not on a list/quote line: caller inserts a plain newline.
    public static func newline(in text: NSString, selection: NSRange) -> ComposerEdit? {
        let sel = clamp(selection, text)
        let lr = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let p = parsePrefix(text, lr)
        guard p.isList || p.isQuote, NSMaxRange(sel) <= p.lineEnd else { return nil }
        let prefixEnd = p.isList ? p.markerEnd : p.quoteEnd
        guard sel.location >= prefixEnd else { return nil }
        guard !ComposerMarkdownIndex(text: text).isInsideCodeBlock(sel.location) else { return nil }

        var restEmpty = true
        var k = prefixEnd
        while k < p.lineEnd {
            if !isBlank(text.character(at: k)) { restEmpty = false; break }
            k += 1
        }
        if restEmpty, sel.length == 0 {
            let from = (p.isList && p.isQuote) ? p.quoteEnd : p.lineStart
            return ComposerEdit(
                range: NSRange(location: from, length: p.lineEnd - from), replacement: "",
                selection: NSRange(location: from, length: 0))
        }
        var prefix = p.quoteEnd > p.lineStart ? text.substring(with: NSRange(location: p.lineStart, length: p.quoteEnd - p.lineStart)) : ""
        if p.isList {
            prefix += text.substring(with: NSRange(location: p.quoteEnd, length: p.markerStart - p.quoteEnd))
            switch p.kind {
            case let .bullet(c): prefix += "\(c) "
            case let .ordered(n, delim): prefix += "\(n + 1)\(delim) "
            case .none: break
            }
            if p.hasTask { prefix += "[ ] " }
        }
        let insert = "\n" + prefix
        return ComposerEdit(
            range: sel, replacement: insert,
            selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
    }

    // MARK: Indent

    /// Indents (2 spaces, numbered: 3) or outdents list items on the touched lines.
    /// nil → the caret line isn't a list item: caller falls back to normal Tab handling.
    public static func indent(in text: NSString, selection: NSRange, outdent: Bool) -> ComposerEdit? {
        let sel = clamp(selection, text)
        let lines = touchedLines(text, sel)
        guard let firstLine = lines.first else { return nil }
        let first = parsePrefix(text, firstLine)
        guard first.isList else { return nil }
        guard !ComposerMarkdownIndex(text: text).isInsideCodeBlock(sel.location) else { return nil }

        var edits: [PartialEdit] = []
        for line in lines {
            let p = parsePrefix(text, line)
            guard p.isList else { continue }
            var width = 2
            if case .ordered = p.kind { width = 3 }
            if outdent {
                var k = 0
                let start = p.quoteEnd
                if start < p.markerStart, text.character(at: start) == 9 {
                    k = 1
                } else {
                    while k < width, start + k < p.markerStart, text.character(at: start + k) == 32 { k += 1 }
                }
                if k > 0 { edits.append(PartialEdit(loc: start, removeLen: k, insert: "")) }
            } else {
                edits.append(PartialEdit(loc: p.quoteEnd, removeLen: 0, insert: String(repeating: " ", count: width)))
            }
        }
        guard !edits.isEmpty else {
            return ComposerEdit(range: NSRange(location: sel.location, length: 0), replacement: "", selection: sel)
        }
        return compose(edits, text, sel)
    }

    // MARK: Fence auto-close

    /// Call after the user typed `typed` at `location` (already in `text`). nil → nothing to do.
    public static func autoCloseFence(in text: NSString, typedAt location: Int) -> ComposerEdit? {
        guard location >= 0, location < text.length, text.character(at: location) == 96 else { return nil }
        let lr = text.lineRange(for: NSRange(location: location, length: 0))
        var lineEnd = NSMaxRange(lr)
        while lineEnd > lr.location, isBreak(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
        guard lineEnd == location + 1, lineEnd - lr.location >= 3 else { return nil }
        var i = lr.location
        while i < lineEnd, text.character(at: i) == 32 { i += 1 }
        guard i - lr.location <= 3, lineEnd - i == 3 else { return nil }
        for k in i..<lineEnd where text.character(at: k) != 96 { return nil }

        let index = ComposerMarkdownIndex(text: text)
        // An odd number of earlier fences means this line closes a block; a later fence means it already pairs.
        let before = index.fences.filter { $0.location < lr.location }.count
        let after = index.fences.filter { $0.location > lr.location }.count
        guard before & 1 == 0, after == 0 else { return nil }
        let indent = text.substring(with: NSRange(location: lr.location, length: i - lr.location))
        let insert = "\n" + indent + "```"
        return ComposerEdit(
            range: NSRange(location: lineEnd, length: 0), replacement: insert,
            selection: NSRange(location: lineEnd, length: 0))
    }

    // MARK: Helpers

    private static func clamp(_ r: NSRange, _ text: NSString) -> NSRange {
        let loc = min(max(r.location, 0), text.length)
        let upper = min(max(NSMaxRange(r), loc), text.length)
        return NSRange(location: loc, length: upper - loc)
    }

    private static func isBreak(_ c: unichar) -> Bool { mdIsLineBreak(c) }

    private enum ListKind { case none, bullet(Character), ordered(Int, Character) }

    private struct LinePrefix {
        var lineStart = 0
        var lineEnd = 0
        var indentEnd = 0
        /// End of the `>` prefix (== lineStart when the line isn't quoted).
        var quoteEnd = 0
        var markerStart = 0
        var markerEnd = 0
        var kind = ListKind.none
        var hasTask = false
        var isList: Bool { if case .none = kind { false } else { true } }
        var isQuote: Bool { quoteEnd > lineStart }
    }

    private static func parsePrefix(_ text: NSString, _ lr: NSRange) -> LinePrefix {
        var p = LinePrefix()
        p.lineStart = lr.location
        var end = NSMaxRange(lr)
        while end > lr.location, isBreak(text.character(at: end - 1)) { end -= 1 }
        p.lineEnd = end
        var i = lr.location
        while i < end, isBlank(text.character(at: i)) { i += 1 }
        p.indentEnd = i
        var quoted = false
        while i < end, text.character(at: i) == 62 {
            i += 1
            if i < end, text.character(at: i) == 32 { i += 1 }
            quoted = true
        }
        p.quoteEnd = quoted ? i : lr.location
        var j = i
        while j < end, isBlank(text.character(at: j)) { j += 1 }
        p.markerStart = j
        p.markerEnd = j
        guard j < end else { return p }
        let c = text.character(at: j)
        var k = j
        if c == 45 || c == 42 || c == 43 {
            p.kind = .bullet(Character(UnicodeScalar(c)!))
            k += 1
        } else if c >= 48, c <= 57 {
            var n = 0
            var digits = 0
            while k < end, text.character(at: k) >= 48, text.character(at: k) <= 57, digits < 10 {
                n = n * 10 + Int(text.character(at: k) - 48)
                k += 1
                digits += 1
            }
            guard digits <= 9, k < end, text.character(at: k) == 46 || text.character(at: k) == 41 else { return p }
            p.kind = .ordered(n, Character(UnicodeScalar(text.character(at: k))!))
            k += 1
        } else {
            return p
        }
        guard k < end, isBlank(text.character(at: k)) else {
            p.kind = .none
            return p
        }
        var m = k + 1
        if m + 2 < end, text.character(at: m) == 91,
           [32, 120, 88].contains(text.character(at: m + 1)), text.character(at: m + 2) == 93,
           m + 3 == end || isBlank(text.character(at: m + 3)) {
            m += m + 3 < end ? 4 : 3
            p.hasTask = true
        }
        p.markerEnd = m
        return p
    }

    private static func isBlankLine(_ text: NSString, _ p: LinePrefix) -> Bool {
        var k = p.lineStart
        while k < p.lineEnd {
            if !isBlank(text.character(at: k)) { return false }
            k += 1
        }
        return true
    }

    /// Where inline text starts on a line (after indent, quote, list marker or heading hashes).
    private static func contentStart(_ text: NSString, _ lr: NSRange) -> Int {
        let p = parsePrefix(text, lr)
        var start = p.isList ? p.markerEnd : (p.isQuote ? p.quoteEnd : p.indentEnd)
        while start < p.lineEnd, isBlank(text.character(at: start)) { start += 1 }
        var h = start
        while h < p.lineEnd, h - start < 6, text.character(at: h) == 35 { h += 1 }
        if h > start, h < p.lineEnd, isBlank(text.character(at: h)) { start = h + 1 }
        return start
    }

    /// Line ranges touched by the selection (a selection ending at a line start excludes that line).
    private static func touchedLines(_ text: NSString, _ sel: NSRange) -> [NSRange] {
        var lines: [NSRange] = []
        var pos = sel.location
        let upper = NSMaxRange(sel)
        repeat {
            let lr = text.lineRange(for: NSRange(location: pos, length: 0))
            lines.append(lr)
            if NSMaxRange(lr) <= pos { break }
            pos = NSMaxRange(lr)
        } while pos < upper
        return lines
    }

    private struct PartialEdit {
        var loc: Int
        var removeLen: Int
        var insert: String
    }

    /// Merges ascending, non-overlapping edits into one replacement and maps the selection through them.
    private static func compose(_ edits: [PartialEdit], _ text: NSString, _ sel: NSRange) -> ComposerEdit {
        let first = edits[0].loc
        let last = edits[edits.count - 1]
        var replacement = ""
        var cursor = first
        for e in edits {
            if e.loc > cursor { replacement += text.substring(with: NSRange(location: cursor, length: e.loc - cursor)) }
            replacement += e.insert
            cursor = e.loc + e.removeLen
        }
        func map(_ q: Int, strict: Bool) -> Int {
            var delta = 0
            for e in edits {
                let insLen = (e.insert as NSString).length
                if q >= e.loc + e.removeLen {
                    if strict, e.removeLen == 0, q == e.loc { continue }
                    delta += insLen - e.removeLen
                } else if q > e.loc {
                    delta += e.loc + insLen - q
                }
            }
            return q + delta
        }
        let start = map(sel.location, strict: sel.length > 0)
        let end = map(NSMaxRange(sel), strict: false)
        return ComposerEdit(
            range: NSRange(location: first, length: last.loc + last.removeLen - first),
            replacement: replacement,
            selection: NSRange(location: start, length: max(0, end - start)))
    }
}
