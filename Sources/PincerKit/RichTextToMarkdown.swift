import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Converts pasted rich text (HTML or attributed strings) to Markdown without WebKit. Pure and thread-safe.
public enum RichTextToMarkdown {
    /// Lightweight tag walker (no WebKit), safe off main. nil when the HTML has no semantic formatting
    /// (then the caller pastes plain text verbatim). Handles b/strong, i/em, s/del/strike, code, pre,
    /// a[href], h1-h6, ul/ol/li (nested), blockquote, p, div, br, entities; drops script/style/head.
    public static func markdown(fromHTML html: String) -> String? {
        var converter = HTMLMarkdownConverter()
        return converter.convert(html)
    }

    /// Walks font traits (CTFont symbolic traits: bold/italic/monospace), strikethrough and link attributes.
    /// nil when no run carries formatting. Safe off main.
    public static func markdown(from attributed: NSAttributedString) -> String? {
        let length = attributed.length
        guard length > 0 else { return nil }
        struct Style: Equatable {
            var bold = false, italic = false, mono = false, strike = false
            var link: String?
            var isPlain: Bool { !bold && !italic && !mono && !strike && link == nil }
        }
        let string = attributed.string as NSString
        var segments: [(text: String, style: Style)] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attrs, range, _ in
            var style = Style()
            if let font = attrs[NSAttributedString.Key("NSFont")] {
                let traits = fontTraits(font)
                style.bold = traits.bold
                style.italic = traits.italic
                style.mono = traits.mono
            }
            if let n = attrs[NSAttributedString.Key("NSStrikethrough")] as? NSNumber, n.intValue != 0 { style.strike = true }
            if let link = attrs[NSAttributedString.Key("NSLink")] {
                style.link = (link as? URL)?.absoluteString ?? (link as? String) ?? (link as? NSURL)?.absoluteString
                if style.link?.isEmpty == true { style.link = nil }
            }
            let text = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            if let last = segments.last, last.style == style {
                segments[segments.count - 1].text += text
            } else {
                segments.append((text, style))
            }
        }
        let visible = segments.filter { !$0.text.allSatisfy { $0.isWhitespace } }
        if !visible.isEmpty, visible.allSatisfy({ $0.style.mono }) { return nil }
        guard segments.contains(where: { !$0.style.isPlain && !$0.text.allSatisfy { $0.isWhitespace } }) else { return nil }

        var result = ""
        var wrote = false
        for (text, style) in segments {
            if style.isPlain {
                result += escapeMarkdown(text)
                continue
            }
            var pieces: [String] = []
            for line in text.components(separatedBy: "\n") {
                let scalars = Array(line.unicodeScalars)
                var a = 0
                var b = scalars.count
                while a < b, isInlineSpace(scalars[a]) { a += 1 }
                while b > a, isInlineSpace(scalars[b - 1]) { b -= 1 }
                if a == b {
                    pieces.append(line)
                    continue
                }
                var core = String(String.UnicodeScalarView(scalars[a..<b]))
                if style.mono {
                    core = codeSpan(core)
                } else {
                    core = escapeMarkdown(core)
                    if let url = style.link { core = "[\(core)](\(encodeURL(url)))" }
                    if style.strike { core = "~~\(core)~~" }
                    if style.bold { core = "**\(core)**" }
                    if style.italic {
                        let marker = (a == 0 && (result.unicodeScalars.last.map(isAlnum) ?? false)) ? "*" : "_"
                        core = "\(marker)\(core)\(marker)"
                    }
                }
                pieces.append(String(String.UnicodeScalarView(scalars[0..<a])) + core + String(String.UnicodeScalarView(scalars[b...])))
            }
            result += pieces.joined(separator: "\n")
            wrote = true
        }
        return wrote ? result : nil
    }

    private static func fontTraits(_ font: Any) -> (bold: Bool, italic: Bool, mono: Bool) {
        #if canImport(CoreText)
        let object = font as AnyObject
        guard CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID() else { return (false, false, false) }
        let ct = unsafeBitCast(object, to: CTFont.self)
        let traits = CTFontGetSymbolicTraits(ct)
        return (traits.contains(.traitBold), traits.contains(.traitItalic), traits.contains(.traitMonoSpace))
        #else
        return (false, false, false)
        #endif
    }
}

// MARK: Shared helpers

private func isInlineSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\u{A0}" }

private func isAlnum(_ s: Unicode.Scalar) -> Bool {
    s.properties.isAlphabetic || (s.value >= 48 && s.value <= 57)
}

/// Escapes the few characters that would otherwise turn plain pasted text into Markdown styling.
func escapeMarkdown(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0 == "*" || $0 == "_" || $0 == "`" }) else { return s }
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, c) in scalars.enumerated() {
        switch c {
        case "*", "`":
            out.append("\\")
        case "_":
            let prev = i > 0 && isAlnum(scalars[i - 1])
            let next = i + 1 < scalars.count && isAlnum(scalars[i + 1])
            if !(prev && next) { out.append("\\") }
        default:
            break
        }
        out.append(c)
    }
    return String(out)
}

private func codeSpan(_ s: String) -> String {
    guard s.contains("`") else { return "`\(s)`" }
    return "`` \(s) ``"
}

private func encodeURL(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case " ": out += "%20"
        case "(": out += "%28"
        case ")": out += "%29"
        default: out.unicodeScalars.append(c)
        }
    }
    return out
}

// MARK: HTML

private struct HTMLMarkdownConverter {
    enum Style { case strong, emphasis, strike, code, link }

    struct Entry {
        var tag: String
        var styles: [Style]
        var start: Int?
        var href: String?
        var semantic = false
    }

    var out: [UInt8] = []
    var atLineStart = true
    var lastLineBlank = true
    var pendingBlank = false
    var quoteDepth = 0
    var lists: [(ordered: Bool, counter: Int, width: Int)] = []
    var pendingMarker: [UInt8]?
    var stack: [Entry] = []
    var codeDepth = 0
    var inPre = false
    var preAwaiting = false
    var preFirst = false
    var skipName: String?
    var skipDepth = 0
    var hasFormatting = false

    mutating func convert(_ html: String) -> String? {
        let bytes = Array(html.utf8)
        let n = bytes.count
        var i = 0
        var textStart = 0
        while i < n {
            guard bytes[i] == 60 else { i += 1; continue }
            guard i + 1 < n else { break }
            let next = bytes[i + 1]
            let isTag = next == 33 || next == 63 || next == 47 || isLetter(next)
            guard isTag else { i += 1; continue }
            if i > textStart { handleText(bytes, textStart, i) }
            if next == 33 || next == 63 {
                if next == 33, matches(bytes, i, "<!--") {
                    i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? n
                } else {
                    i = indexOf(bytes, 62, from: i).map { $0 + 1 } ?? n
                }
            } else if next == 47 {
                var j = i + 2
                let nameStart = j
                while j < n, isNameByte(bytes[j]) { j += 1 }
                let name = lower(bytes, nameStart, j)
                i = indexOf(bytes, 62, from: j).map { $0 + 1 } ?? n
                handleClose(name)
            } else {
                var j = i + 1
                let nameStart = j
                while j < n, isNameByte(bytes[j]) { j += 1 }
                let name = lower(bytes, nameStart, j)
                var attrs: [String: String] = [:]
                var selfClosing = false
                while j < n {
                    while j < n, bytes[j] == 32 || bytes[j] == 9 || bytes[j] == 10 || bytes[j] == 13 { j += 1 }
                    if j >= n { break }
                    if bytes[j] == 62 { j += 1; break }
                    if bytes[j] == 47 { selfClosing = true; j += 1; continue }
                    let aStart = j
                    while j < n, !(bytes[j] == 32 || bytes[j] == 9 || bytes[j] == 10 || bytes[j] == 13 || bytes[j] == 61 || bytes[j] == 62 || bytes[j] == 47) { j += 1 }
                    let aName = lower(bytes, aStart, j)
                    while j < n, bytes[j] == 32 || bytes[j] == 9 || bytes[j] == 10 || bytes[j] == 13 { j += 1 }
                    var value = ""
                    if j < n, bytes[j] == 61 {
                        j += 1
                        while j < n, bytes[j] == 32 || bytes[j] == 9 || bytes[j] == 10 || bytes[j] == 13 { j += 1 }
                        if j < n, bytes[j] == 34 || bytes[j] == 39 {
                            let q = bytes[j]
                            let vs = j + 1
                            j = vs
                            while j < n, bytes[j] != q { j += 1 }
                            value = String(decoding: bytes[vs..<min(j, n)], as: UTF8.self)
                            j = min(j + 1, n)
                        } else {
                            let vs = j
                            while j < n, !(bytes[j] == 32 || bytes[j] == 9 || bytes[j] == 10 || bytes[j] == 13 || bytes[j] == 62) { j += 1 }
                            value = String(decoding: bytes[vs..<j], as: UTF8.self)
                        }
                    }
                    if aName == "href" || aName == "style" || aName == "class" || aName == "start" {
                        attrs[aName] = decodeEntities(value)
                    }
                }
                i = j
                handleOpen(name, attrs, selfClosing: selfClosing)
                if skipName != nil, name == "script" || name == "style" {
                    // Raw-text element: jump to its end tag.
                    let end = find(bytes, "</" + name, from: i, caseInsensitive: true) ?? n
                    i = end
                }
            }
            textStart = i
        }
        if textStart < n { handleText(bytes, textStart, n) }
        while !stack.isEmpty { finalize(stack.removeLast()) }
        guard hasFormatting else { return nil }
        let result = cleanup(String(decoding: out, as: UTF8.self))
        return result.isEmpty ? nil : result
    }

    // MARK: Tags

    private static let skipTags: Set<String> = ["script", "style", "head", "title", "template", "noscript"]

    private mutating func handleOpen(_ name: String, _ attrs: [String: String], selfClosing: Bool) {
        if skipName != nil {
            if name == skipName { skipDepth += 1 }
            return
        }
        if Self.skipTags.contains(name) {
            if !selfClosing { skipName = name; skipDepth = 1 }
            return
        }
        switch name {
        case "br":
            newline()
        case "hr":
            beginBlock(blank: true)
            write(Array("---".utf8))
            endBlock(blank: true)
        case "p":
            beginBlock(blank: true)
        case "div", "tr", "table", "section", "article", "header", "footer", "figure":
            beginBlock(blank: false)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            hasFormatting = true
            beginBlock(blank: true)
            write(Array((String(repeating: "#", count: Int(String(name.last!))!) + " ").utf8))
        case "blockquote":
            hasFormatting = true
            beginBlock(blank: true)
            if pendingBlank, !out.isEmpty, !lastLineBlank { blankLine() }
            pendingBlank = false
            quoteDepth += 1
        case "ul", "ol":
            if pendingMarker != nil {
                startLine()
                breakLine()
            }
            beginBlock(blank: lists.isEmpty)
            let start = Int(attrs["start"] ?? "") ?? 1
            lists.append((name == "ol", start - 1, 2))
        case "li":
            hasFormatting = true
            beginBlock(blank: false)
            if lists.isEmpty { lists.append((false, 0, 2)) }
            var marker = "- "
            if lists[lists.count - 1].ordered {
                lists[lists.count - 1].counter += 1
                marker = "\(lists[lists.count - 1].counter). "
            }
            lists[lists.count - 1].width = marker.utf8.count
            pendingMarker = Array(marker.utf8)
        case "pre":
            beginBlock(blank: true)
            write(Array("```".utf8))
            inPre = true
            preAwaiting = true
            preFirst = true
        case "b", "strong":
            pushInline(name, attrs, base: isNormalWeight(attrs["style"]) ? [] : [.strong])
        case "i", "em", "cite", "dfn":
            pushInline(name, attrs, base: [.emphasis])
        case "s", "del", "strike":
            pushInline(name, attrs, base: [.strike])
        case "code", "kbd", "samp", "tt":
            if inPre {
                if preAwaiting, let cls = attrs["class"], let lang = languageClass(cls) {
                    out += Array(lang.utf8)
                }
                hasFormatting = true
            } else {
                pushInline(name, attrs, base: [.code])
            }
        case "a":
            if let href = attrs["href"], !href.isEmpty, !inPre {
                pushInline(name, attrs, base: [.link], href: href)
            } else {
                pushInline(name, attrs, base: [])
            }
        case "span", "font", "u", "mark", "small", "sub", "sup":
            pushInline(name, attrs, base: [])
        default:
            break
        }
    }

    private mutating func pushInline(_ name: String, _ attrs: [String: String], base: [Style], href: String? = nil) {
        guard !inPre, codeDepth == 0 else { return }
        var styles = base
        if let style = attrs["style"]?.lowercased().replacingOccurrences(of: " ", with: "") {
            if !styles.contains(.strong),
               style.contains("font-weight:bold") || style.contains("font-weight:7") || style.contains("font-weight:8") || style.contains("font-weight:9") || style.contains("font-weight:600") {
                styles.append(.strong)
            }
            if !styles.contains(.emphasis), style.contains("font-style:italic") { styles.append(.emphasis) }
            if !styles.contains(.strike), style.contains("line-through") { styles.append(.strike) }
        }
        if styles.contains(.code) { codeDepth += 1 }
        stack.append(Entry(tag: name, styles: styles, start: atLineStart ? nil : out.count, href: href,
                           semantic: !base.isEmpty))
    }

    private func isNormalWeight(_ style: String?) -> Bool {
        guard let s = style?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return s.contains("font-weight:normal") || s.contains("font-weight:400")
    }

    private func languageClass(_ cls: String) -> String? {
        for part in cls.split(separator: " ") {
            if part.hasPrefix("language-") { return String(part.dropFirst(9)) }
            if part.hasPrefix("lang-") { return String(part.dropFirst(5)) }
        }
        return nil
    }

    private mutating func handleClose(_ name: String) {
        if let skip = skipName {
            if name == skip {
                skipDepth -= 1
                if skipDepth == 0 { skipName = nil }
            }
            return
        }
        switch name {
        case "p", "h1", "h2", "h3", "h4", "h5", "h6":
            endBlock(blank: true)
        case "div", "tr", "table", "section", "article", "header", "footer", "figure":
            endBlock(blank: false)
        case "blockquote":
            endBlock(blank: true)
            quoteDepth = max(0, quoteDepth - 1)
        case "ul", "ol":
            endBlock(blank: lists.count <= 1)
            if !lists.isEmpty { lists.removeLast() }
        case "li":
            breakLine()
            pendingMarker = nil
        case "td", "th":
            if !atLineStart, out.last != 32 { out.append(32) }
        case "pre":
            if preAwaiting { out.append(10); atLineStart = true; preAwaiting = false }
            breakLine()
            write(Array("```".utf8))
            inPre = false
            endBlock(blank: true)
        default:
            guard let idx = stack.lastIndex(where: { $0.tag == name }) else { return }
            while stack.count > idx {
                finalize(stack.removeLast())
            }
        }
    }

    // MARK: Output

    private func quotePrefix() -> [UInt8] {
        Array(String(repeating: "> ", count: quoteDepth).utf8)
    }

    /// Emits any pending blank line, the quote prefix and list marker/indent when a new line begins.
    private mutating func startLine() {
        guard atLineStart else { return }
        if pendingBlank, !out.isEmpty, !lastLineBlank { blankLine() }
        pendingBlank = false
        out += quotePrefix()
        if !lists.isEmpty {
            if let marker = pendingMarker {
                let indent = lists.dropLast().reduce(0) { $0 + $1.width }
                out += [UInt8](repeating: 32, count: indent)
                out += marker
                pendingMarker = nil
            } else {
                out += [UInt8](repeating: 32, count: lists.reduce(0) { $0 + $1.width })
            }
        }
        atLineStart = false
        for k in stack.indices where stack[k].start == nil { stack[k].start = out.count }
    }

    private mutating func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        startLine()
        out += bytes
        lastLineBlank = false
    }

    private mutating func blankLine() {
        var prefix = quotePrefix()
        while prefix.last == 32 { prefix.removeLast() }
        out += prefix
        out.append(10)
        lastLineBlank = true
    }

    private mutating func newline() {
        if atLineStart {
            if !out.isEmpty { blankLine() }
        } else {
            out.append(10)
            atLineStart = true
        }
    }

    private mutating func breakLine() {
        if !atLineStart {
            out.append(10)
            atLineStart = true
        }
    }

    private mutating func beginBlock(blank: Bool) {
        breakLine()
        if blank, lists.isEmpty { pendingBlank = true }
    }

    private mutating func endBlock(blank: Bool) {
        breakLine()
        if blank, lists.isEmpty { pendingBlank = true }
    }

    // MARK: Text

    private mutating func handleText(_ bytes: [UInt8], _ a: Int, _ b: Int) {
        guard skipName == nil else { return }
        let text = decodeEntities(String(decoding: bytes[a..<b], as: UTF8.self))
        if inPre {
            preText(text)
            return
        }
        var word: [Unicode.Scalar] = []
        func flush(_ me: inout HTMLMarkdownConverter) {
            guard !word.isEmpty else { return }
            let s = String(String.UnicodeScalarView(word))
            me.write(Array((me.codeDepth > 0 ? s : escapeMarkdown(s)).utf8))
            word.removeAll(keepingCapacity: true)
        }
        for c in text.unicodeScalars {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" {
                flush(&self)
                if !atLineStart, out.last != 32 { write([32]) }
            } else {
                word.append(c)
            }
        }
        flush(&self)
    }

    private mutating func preText(_ raw: String) {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if preFirst {
            if text.hasPrefix("\n") { text.removeFirst() }
            preFirst = text.isEmpty
        }
        guard !text.isEmpty else { return }
        if preAwaiting {
            out.append(10)
            atLineStart = true
            preAwaiting = false
        }
        let lines = text.components(separatedBy: "\n")
        for (k, line) in lines.enumerated() {
            if k > 0 { newline() }
            if !line.isEmpty { write(Array(line.utf8)) }
        }
    }

    private mutating func finalize(_ entry: Entry) {
        if entry.styles.contains(.code) { codeDepth = max(0, codeDepth - 1) }
        guard let start = entry.start, start <= out.count, !entry.styles.isEmpty else { return }
        var seg = Array(out[start...])
        if seg.contains(10) { return }
        var lead = 0
        while lead < seg.count, seg[lead] == 32 { lead += 1 }
        var trail = 0
        while trail < seg.count - lead, seg[seg.count - 1 - trail] == 32 { trail += 1 }
        guard lead + trail < seg.count else { return }
        var core = String(decoding: seg[lead..<(seg.count - trail)], as: UTF8.self)
        let prevByte: UInt8? = start > 0 ? out[start - 1] : nil
        for style in entry.styles {
            switch style {
            case .code:
                core = codeSpan(core)
            case .link:
                if let href = entry.href, core != href { core = "[\(core)](\(encodeURL(href)))" }
            case .strong:
                core = "**\(core)**"
            case .strike:
                core = "~~\(core)~~"
            case .emphasis:
                let intraword = lead == 0 && (prevByte.map { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 >= 0x80 } ?? false)
                let m = intraword ? "*" : "_"
                core = "\(m)\(core)\(m)"
            }
        }
        seg = [UInt8](repeating: 32, count: lead) + Array(core.utf8) + [UInt8](repeating: 32, count: trail)
        out.replaceSubrange(start..., with: seg)
        if entry.semantic { hasFormatting = true }
    }

    // MARK: Cleanup

    private func cleanup(_ s: String) -> String {
        var lines: [String] = []
        var inFence = false
        var previousBlank = true
        for raw in s.components(separatedBy: "\n") {
            var line = raw
            var probe = Substring(line)
            while probe.hasPrefix(">") || probe.hasPrefix(" ") { probe = probe.dropFirst() }
            if probe.hasPrefix("```") { inFence.toggle() }
            if !inFence {
                while line.hasSuffix(" ") { line.removeLast() }
                let blank = line.isEmpty || line.allSatisfy { $0 == ">" || $0 == " " }
                if blank, previousBlank { continue }
                previousBlank = blank
            } else {
                previousBlank = false
            }
            lines.append(line)
        }
        while let last = lines.last, last.isEmpty || last.allSatisfy({ $0 == ">" || $0 == " " }) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Byte utilities

    private func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }

    private func isNameByte(_ b: UInt8) -> Bool { isLetter(b) || (b >= 48 && b <= 57) || b == 45 || b == 58 || b == 95 }

    private func lower(_ bytes: [UInt8], _ a: Int, _ b: Int) -> String {
        String(decoding: bytes[a..<b].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }

    private func matches(_ bytes: [UInt8], _ i: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count else { return false }
        for k in 0..<u.count where bytes[i + k] != u[k] { return false }
        return true
    }

    private func indexOf(_ bytes: [UInt8], _ b: UInt8, from: Int) -> Int? {
        var i = from
        var quote: UInt8 = 0
        while i < bytes.count {
            let c = bytes[i]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 34 || c == 39, i > from, bytes[i - 1] == 61 {
                quote = c
            } else if c == b {
                return i
            }
            i += 1
        }
        return nil
    }

    private func find(_ bytes: [UInt8], _ s: String, from: Int, caseInsensitive: Bool = false) -> Int? {
        let u = Array(s.utf8)
        guard bytes.count >= u.count, from <= bytes.count - u.count else { return nil }
        var i = from
        while i <= bytes.count - u.count {
            var ok = true
            for k in 0..<u.count {
                var c = bytes[i + k]
                if caseInsensitive, c >= 65, c <= 90 { c += 32 }
                if c != u[k] { ok = false; break }
            }
            if ok { return i }
            i += 1
        }
        return nil
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "copy": "©", "reg": "®", "trade": "™",
        "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "times": "×", "deg": "°",
    ]

    private func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "&", let semi = scalars[i..<min(i + 12, scalars.count)].firstIndex(of: ";") {
                let name = String(String.UnicodeScalarView(scalars[(i + 1)..<semi]))
                var decoded: String?
                if name.hasPrefix("#") {
                    let body = name.dropFirst()
                    let value = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                    if let value, let scalar = Unicode.Scalar(value) { decoded = String(Character(scalar)) }
                } else {
                    decoded = Self.entities[name]
                }
                if let decoded {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = semi + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
