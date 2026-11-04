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

    /// Pasting a single http(s)/mailto URL over a non-empty selection → `[selection](url)`, caret after it.
    /// nil when the selection is empty, multi-line, inside code or a link, or `pasted` isn't a lone URL.
    public static func pasteLink(_ pasted: String, in text: NSString, selection: NSRange) -> ComposerEdit? {
        let sel = clamp(selection, text)
        guard sel.length > 0 else { return nil }
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = url.lowercased()
        guard !url.isEmpty, !url.contains(where: { $0.isWhitespace }),
              (lower.hasPrefix("http://") && url.count > 7) || (lower.hasPrefix("https://") && url.count > 8)
              || (lower.hasPrefix("mailto:") && url.count > 7) else { return nil }
        let selected = text.substring(with: sel)
        guard !selected.contains(where: { $0.isNewline }) else { return nil }
        guard !ComposerMarkdownIndex(text: text).isInsideCodeBlock(sel.location, in: text) else { return nil }
        let line = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = text.substring(with: line)
        for span in ComposerMarkdown.tokenize(lineText) where span.kind == .inlineCode || span.kind == .link {
            let r = NSRange(location: span.range.location + line.location, length: span.range.length)
            if NSIntersectionRange(r, sel).length > 0 || (r.location <= sel.location && NSMaxRange(sel) <= NSMaxRange(r)) {
                return nil
            }
        }
        let safe = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        let replacement = "[\(selected)](\(safe))"
        return ComposerEdit(
            range: sel, replacement: replacement,
            selection: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
    }

    // MARK: Lists, quotes and headings

    /// Bulleted list: removes the bullets when every touched line has one, else adds `- ` (numbers become bullets).
    public static func toggleList(in text: NSString, selection: NSRange) -> ComposerEdit {
        self.toggleList(ordered: false, in: text, selection: selection)
    }

    /// Numbered list: removes the numbers when every touched line has one, else numbers the lines (bullets become
    /// numbers), continuing a numbered list just above.
    public static func toggleNumberedList(in text: NSString, selection: NSRange) -> ComposerEdit {
        self.toggleList(ordered: true, in: text, selection: selection)
    }

    private static func toggleList(ordered: Bool, in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let prefixes = touchedLines(text, sel).map { parsePrefix(text, $0) }
        let nonBlank = prefixes.filter { !isBlankLine(text, $0) }
        func matches(_ p: LinePrefix) -> Bool {
            switch p.kind {
            case .ordered: ordered
            case .bullet: !ordered
            case .none: false
            }
        }
        var edits: [PartialEdit] = []
        if !nonBlank.isEmpty, nonBlank.allSatisfy(matches) {
            for p in nonBlank {
                edits.append(PartialEdit(loc: p.markerStart, removeLen: p.markerEnd - p.markerStart, insert: ""))
            }
        } else {
            let marker = ordered ? "1." : "-"
            for p in nonBlank.isEmpty ? prefixes : nonBlank where !matches(p) {
                if p.isList {
                    edits.append(PartialEdit(loc: p.markerStart, removeLen: markerLength(text, p), insert: marker))
                } else {
                    edits.append(PartialEdit(loc: p.isQuote ? p.quoteEnd : p.indentEnd, removeLen: 0, insert: marker + " "))
                }
            }
        }
        return self.finish(edits, text, sel)
    }

    /// Removes one `>` level when every touched line is quoted, else quotes the unquoted lines (blank lines
    /// between them too, so the quote stays one block).
    public static func toggleQuote(in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let prefixes = touchedLines(text, sel).map { parsePrefix(text, $0) }
        let nonBlank = prefixes.filter { !isBlankLine(text, $0) }
        var edits: [PartialEdit] = []
        if !nonBlank.isEmpty, nonBlank.allSatisfy(\.isQuote) {
            for p in prefixes where p.isQuote {
                var end = p.indentEnd + 1
                if end < p.lineEnd, text.character(at: end) == 32 { end += 1 }
                edits.append(PartialEdit(loc: p.indentEnd, removeLen: end - p.indentEnd, insert: ""))
            }
        } else {
            for p in prefixes where !p.isQuote {
                let blankInside = prefixes.count > 1 && isBlankLine(text, p)
                edits.append(PartialEdit(loc: p.lineStart, removeLen: 0, insert: blankInside ? ">" : "> "))
            }
        }
        return self.finish(edits, text, sel)
    }

    /// Removes the heading hashes when every touched line is a heading, else makes the lines `## ` headings.
    public static func toggleHeading(in text: NSString, selection: NSRange) -> ComposerEdit {
        let sel = clamp(selection, text)
        let prefixes = touchedLines(text, sel).map { parsePrefix(text, $0) }
        let nonBlank = prefixes.filter { !isBlankLine(text, $0) }
        func textStart(_ p: LinePrefix) -> Int { p.isList ? p.markerEnd : (p.isQuote ? p.quoteEnd : p.indentEnd) }
        func hashes(_ p: LinePrefix) -> NSRange? {
            var start = textStart(p)
            while start < p.lineEnd, isBlank(text.character(at: start)) { start += 1 }
            var h = start
            while h < p.lineEnd, h - start < 7, text.character(at: h) == 35 { h += 1 }
            guard h > start, h - start <= 6, h == p.lineEnd || isBlank(text.character(at: h)) else { return nil }
            return NSRange(location: start, length: (h < p.lineEnd ? h + 1 : h) - start)
        }
        var edits: [PartialEdit] = []
        if !nonBlank.isEmpty, nonBlank.allSatisfy({ hashes($0) != nil }) {
            for p in nonBlank {
                if let r = hashes(p) { edits.append(PartialEdit(loc: r.location, removeLen: r.length, insert: "")) }
            }
        } else {
            for p in nonBlank.isEmpty ? prefixes : nonBlank where hashes(p) == nil {
                edits.append(PartialEdit(loc: textStart(p), removeLen: 0, insert: "## "))
            }
        }
        return self.finish(edits, text, sel)
    }

    /// Composes `edits` (a no-op edit keeping the selection when empty) and renumbers the lists they touch.
    private static func finish(_ edits: [PartialEdit], _ text: NSString, _ sel: NSRange) -> ComposerEdit {
        guard !edits.isEmpty else {
            return ComposerEdit(range: NSRange(location: sel.location, length: 0), replacement: "", selection: sel)
        }
        return self.renumbering(compose(edits, text, sel), in: text)
    }

    // MARK: Renumbering

    /// Renumbers the numbered lists around `range` so each level counts up from its first item (whose number is
    /// kept). A list here is a run of list lines and indented continuation lines; a blank line, plain line or
    /// change of quote depth ends it. nil when nothing changes or the range is inside code.
    public static func renumber(in text: NSString, around range: NSRange, selection: NSRange) -> ComposerEdit? {
        let length = text.length
        guard length > 0 else { return nil }
        let r = clamp(range, text)
        func inList(_ line: NSRange) -> Bool {
            let p = parsePrefix(text, line)
            return p.isList || (p.indentEnd > p.lineStart && p.indentEnd < p.lineEnd)
        }
        var start = text.lineRange(for: NSRange(location: r.location, length: 0)).location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard inList(previous) else { break }
            start = previous.location
        }
        var end = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(r), length: 0)))
        while end < length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            guard inList(next) else { break }
            end = NSMaxRange(next)
        }
        var hasNumbers = false
        var scan = start
        while scan < end, !hasNumbers {
            let line = text.lineRange(for: NSRange(location: scan, length: 0))
            scan = NSMaxRange(line)
            if case .ordered = parsePrefix(text, line).kind { hasNumbers = true }
        }
        guard hasNumbers else { return nil }
        let index = ComposerMarkdownIndex(text: text)
        guard !index.isInsideCodeBlock(start) else { return nil }

        var edits: [PartialEdit] = []
        // Open levels, outermost first: indent column and the last item's kind.
        var levels: [(column: Int, kind: ListKind)] = []
        var quoteDepth = -1
        var pos = start
        while pos < end {
            let line = text.lineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(line)
            let p = parsePrefix(text, line)
            if index.isInsideCodeBlock(line.location) || !(p.isList || (p.indentEnd > p.lineStart && p.indentEnd < p.lineEnd)) {
                levels.removeAll()
                continue
            }
            let depth = p.quoteEnd - p.lineStart
            if depth != quoteDepth {
                levels.removeAll()
                quoteDepth = depth
            }
            guard p.isList else { continue }
            let column = columns(text, p.quoteEnd, p.markerStart)
            while let last = levels.last, last.column > column { levels.removeLast() }
            var kind = p.kind
            if let last = levels.last, last.column == column {
                if case let .ordered(n, d) = last.kind, case let .ordered(current, delim) = p.kind, delim == d, current != n + 1 {
                    let digits = markerLength(text, p) - 1
                    edits.append(PartialEdit(loc: p.markerStart, removeLen: digits, insert: "\(n + 1)"))
                    kind = .ordered(n + 1, d)
                }
                levels[levels.count - 1].kind = kind
            } else {
                levels.append((column, kind))
            }
        }
        guard !edits.isEmpty else { return nil }
        return compose(edits, text, clamp(selection, text))
    }

    /// `edit` followed by `renumber` around what it changed, merged into one edit (one undo step).
    static func renumbering(_ edit: ComposerEdit, in text: NSString) -> ComposerEdit {
        let after = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        let inserted = (edit.replacement as NSString).length
        guard let fix = renumber(in: after, around: NSRange(location: edit.range.location, length: inserted), selection: edit.selection)
        else { return edit }
        let delta = inserted - edit.range.length
        func back(_ q: Int) -> Int {
            if q <= edit.range.location { return q }
            return q >= edit.range.location + inserted ? q - delta : NSMaxRange(edit.range)
        }
        let start = min(edit.range.location, back(fix.range.location))
        let oldEnd = max(NSMaxRange(edit.range), back(NSMaxRange(fix.range)))
        let final = after.replacingCharacters(in: fix.range, with: fix.replacement) as NSString
        let newEnd = oldEnd + final.length - text.length
        return ComposerEdit(
            range: NSRange(location: start, length: oldEnd - start),
            replacement: final.substring(with: NSRange(location: start, length: newEnd - start)),
            selection: fix.selection)
    }

    // MARK: Smart newline

    /// Continues a list item or quote (renumbering the items after it). nil → not on a list/quote line: caller
    /// inserts a plain newline.
    public static func newline(in text: NSString, selection: NSRange) -> ComposerEdit? {
        self.newlineEdit(in: text, selection: selection).map { self.renumbering($0, in: text) }
    }

    private static func newlineEdit(in text: NSString, selection: NSRange) -> ComposerEdit? {
        let sel = clamp(selection, text)
        let lr = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let p = parsePrefix(text, lr)
        guard p.isList || p.isQuote, NSMaxRange(sel) <= p.lineEnd else { return nil }
        let prefixEnd = p.isList ? p.markerEnd : p.quoteEnd
        guard sel.location >= prefixEnd else { return nil }
        guard !ComposerMarkdownIndex(text: text).isInsideCodeBlock(sel.location, in: text) else { return nil }

        var restEmpty = true
        var k = prefixEnd
        while k < p.lineEnd {
            if !isBlank(text.character(at: k)) { restEmpty = false; break }
            k += 1
        }
        if restEmpty, sel.length == 0, p.isList, columns(text, p.quoteEnd, p.markerStart) > 0 {
            let edits = shiftEdits(text, [lr], outdent: true)
            if !edits.isEmpty { return compose(edits, text, NSRange(location: p.markerEnd, length: 0)) }
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
        guard !ComposerMarkdownIndex(text: text).isInsideCodeBlock(sel.location, in: text) else { return nil }

        return self.finish(shiftEdits(text, lines, outdent: outdent), text, sel)
    }

    private static func columns(_ text: NSString, _ from: Int, _ to: Int) -> Int {
        var n = 0
        var i = from
        while i < to { n += text.character(at: i) == 9 ? 4 : 1; i += 1 }
        return n
    }

    private static func markerText(_ kind: ListKind) -> String {
        switch kind {
        case let .bullet(c): "\(c)"
        case let .ordered(n, d): "\(n)\(d)"
        case .none: ""
        }
    }

    /// Indent/outdent edits (indent change + marker adoption) for list lines, top to bottom.
    private static func shiftEdits(_ text: NSString, _ lines: [NSRange], outdent: Bool) -> [PartialEdit] {
        var edits: [PartialEdit] = []
        var moved: [Int: (level: Int, kind: ListKind)] = [:]
        for line in lines {
            let p = parsePrefix(text, line)
            guard p.isList else { continue }
            let level = columns(text, p.quoteEnd, p.markerStart)
            var width = 2
            if case .ordered = p.kind { width = 3 }
            var newLevel = level + width
            if outdent {
                var k = 0
                let start = p.quoteEnd
                if start < p.markerStart, text.character(at: start) == 9 {
                    k = 1
                    newLevel = level - 4
                } else {
                    while k < width, start + k < p.markerStart, text.character(at: start + k) == 32 { k += 1 }
                    newLevel = level - k
                }
                guard k > 0 else { continue }
                edits.append(PartialEdit(loc: start, removeLen: k, insert: ""))
            } else {
                edits.append(PartialEdit(loc: p.quoteEnd, removeLen: 0, insert: String(repeating: " ", count: width)))
            }
            newLevel = max(0, newLevel)

            var newKind = p.kind
            var sibling: ListKind?
            var pos = p.lineStart
            let quoteLen = p.quoteEnd - p.lineStart
            scan: while pos > 0 {
                let lr = text.lineRange(for: NSRange(location: pos - 1, length: 0))
                pos = lr.location
                let q = parsePrefix(text, lr)
                guard q.isList, q.quoteEnd - q.lineStart == quoteLen else { break scan }
                let info = moved[q.lineStart] ?? (columns(text, q.quoteEnd, q.markerStart), q.kind)
                if info.level > newLevel { continue }
                if info.level == newLevel { sibling = info.kind }
                break scan
            }
            switch (sibling, p.kind) {
            case let (.bullet(c)?, _): newKind = .bullet(c)
            case let (.ordered(n, d)?, _): newKind = .ordered(n + 1, d)
            case let (nil, .ordered(_, d)): newKind = .ordered(1, d)
            default: break
            }
            moved[p.lineStart] = (newLevel, newKind)
            let old = text.substring(with: NSRange(location: p.markerStart, length: markerLength(text, p)))
            let new = markerText(newKind)
            if old != new {
                edits.append(PartialEdit(loc: p.markerStart, removeLen: (old as NSString).length, insert: new))
            }
        }
        return edits
    }

    private static func markerLength(_ text: NSString, _ p: LinePrefix) -> Int {
        guard case .ordered = p.kind else { return 1 }
        var k = p.markerStart
        while k < p.lineEnd, text.character(at: k) >= 48, text.character(at: k) <= 57 { k += 1 }
        return k + 1 - p.markerStart
    }

    // MARK: Fence auto-close

    /// Call after the user typed a backtick or tilde at `location` (already in `text`). nil → nothing to do.
    public static func autoCloseFence(in text: NSString, typedAt location: Int) -> ComposerEdit? {
        guard location >= 0, location < text.length else { return nil }
        let marker = text.character(at: location)
        guard marker == 96 || marker == 126 else { return nil }
        let lr = text.lineRange(for: NSRange(location: location, length: 0))
        var lineEnd = NSMaxRange(lr)
        while lineEnd > lr.location, isBreak(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
        guard lineEnd == location + 1, lineEnd - lr.location >= 3 else { return nil }
        var i = lr.location
        while i < lineEnd, text.character(at: i) == 32 { i += 1 }
        guard i - lr.location <= 3, lineEnd - i == 3 else { return nil }
        for k in i..<lineEnd where text.character(at: k) != marker { return nil }

        let index = ComposerMarkdownIndex(text: text)
        // This line must open a block (an even number of fences before it) with nothing after it to pair with.
        let before = index.fences.filter { $0.location < lr.location }.count
        let after = index.fences.filter { $0.location > lr.location }.count
        guard before & 1 == 0, after == 0 else { return nil }
        let indent = text.substring(with: NSRange(location: lr.location, length: i - lr.location))
        let insert = "\n" + indent + String(repeating: Character(UnicodeScalar(marker)!), count: 3)
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

/// Follow-up edits once the user's own change has landed in the text view: fence auto-close and list renumbering.
/// Each is its own undo step.
public enum ComposerTextFixups {
    /// Where to renumber after replacing `range` with `replacement`, when that adds or removes a line break.
    public static func renumberRange(in text: NSString, replacing range: NSRange, with replacement: String) -> NSRange? {
        let location = min(max(range.location, 0), text.length)
        let upper = min(max(NSMaxRange(range), location), text.length)
        var breaks = replacement.utf16.contains { mdIsLineBreak($0) }
        var k = location
        while !breaks, k < upper {
            breaks = mdIsLineBreak(text.character(at: k))
            k += 1
        }
        return breaks ? NSRange(location: location, length: (replacement as NSString).length) : nil
    }

    /// The fix-up for the change that just landed, if any.
    public static func edit(in text: NSString, typedFenceAt fence: Int?, renumber: NSRange?, selection: NSRange) -> ComposerEdit? {
        if let fence, let edit = ComposerFormatting.autoCloseFence(in: text, typedAt: fence) { return edit }
        guard let renumber else { return nil }
        return ComposerFormatting.renumber(in: text, around: renumber, selection: selection)
    }
}
