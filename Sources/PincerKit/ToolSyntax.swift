import Foundation

/// A cheap, pure, line-oriented tokenizer for tool cards: JSON output and arguments, and code in `read`
/// results. It only reports ranges (UTF-16, like `NSRange`) of the text it is given, so a caller can add
/// foreground colors without changing the text. Linear in the text length, no regular expressions.
public enum ToolSyntax {
    public enum TokenKind: Sendable, Hashable { case key, string, number, keyword, comment }

    public struct Token: Sendable, Hashable {
        public let range: NSRange
        public let kind: TokenKind
        public init(range: NSRange, kind: TokenKind) {
            self.range = range
            self.kind = kind
        }
    }

    public enum Language: Sendable, Hashable {
        case json, swift, javascript, python, shell, ruby, go, rust, cFamily, yaml
    }

    /// The language of a file by its extension; nil for anything else (markdown, plain text, unknown).
    public static func language(forPath path: String) -> Language? {
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return nil }
        switch path[path.index(after: dot)...].lowercased() {
        case "json", "jsonc", "json5": return .json
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .javascript
        case "py", "pyi": return .python
        case "sh", "bash", "zsh": return .shell
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "cs": return .cFamily
        case "yaml", "yml": return .yaml
        default: return nil
        }
    }

    /// Whether `text` looks like a JSON document: starts with `{` or `[` followed by something JSON-like.
    public static func looksLikeJSON(_ text: String) -> Bool {
        var first: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" { continue }
            if first == nil {
                guard scalar == "{" || scalar == "[" else { return false }
                first = scalar
                continue
            }
            switch scalar {
            case "\"", "{", "[", "}", "]", "-", "0"..."9", "t", "f", "n": return true
            default: return false
            }
        }
        return false
    }

    /// Tokens of `text` in `language`, ordered and non-overlapping.
    public static func tokens(in text: String, language: Language) -> [Token] {
        let units = Array(text.utf16)
        if language == .json { return self.json(units, from: 0, to: units.count) }
        return self.code(units, language: language)
    }

    /// Tokens of a JSON fragment (for example a nested argument value) that starts at `offset` in the
    /// text the returned ranges refer to.
    public static func jsonTokens(in fragment: String, offset: Int = 0) -> [Token] {
        let units = Array(fragment.utf16)
        return self.json(units, from: 0, to: units.count).map {
            Token(range: NSRange(location: $0.range.location + offset, length: $0.range.length), kind: $0.kind)
        }
    }

    // MARK: JSON

    private static func json(_ u: [UInt16], from start: Int, to end: Int) -> [Token] {
        var tokens: [Token] = []
        var i = start
        while i < end {
            let c = u[i]
            if c == quote {
                let stop = self.stringEnd(u, from: i + 1, to: end, quote: quote, multiline: false)
                var j = stop
                while j < end, u[j] == space || u[j] == tab { j += 1 }
                let isKey = j < end && u[j] == colon
                tokens.append(Token(range: NSRange(location: i, length: stop - i), kind: isKey ? .key : .string))
                i = stop
            } else if c == minus || isDigit(c) {
                let stop = self.numberEnd(u, from: i, to: end)
                tokens.append(Token(range: NSRange(location: i, length: stop - i), kind: .number))
                i = stop
            } else if isLower(c) {
                var stop = i
                while stop < end, isLower(u[stop]) { stop += 1 }
                if let word = word(u, i, stop), word == "true" || word == "false" || word == "null" {
                    tokens.append(Token(range: NSRange(location: i, length: stop - i), kind: .keyword))
                }
                i = stop
            } else {
                i += 1
            }
        }
        return tokens
    }

    // MARK: Code

    private struct Rules {
        let keywords: Set<String>
        let lineComments: [[UInt16]]
        let blockComments: Bool
        let quotes: [UInt16]
        let backtickMultiline: Bool
        let tripleQuotes: Bool
        let hashComment: Bool
    }

    private static func rules(for language: Language) -> Rules {
        func set(_ words: String) -> Set<String> { Set(words.split(separator: " ").map(String.init)) }
        let slash = [[slashU, slashU]]
        switch language {
        case .swift:
            return Rules(keywords: set("func let var if else guard return struct class enum protocol extension import for in while switch case default break continue do try catch throw throws async await actor init self Self nil true false static private public internal fileprivate final override where as is some any typealias defer"),
                         lineComments: slash, blockComments: true, quotes: [quote], backtickMultiline: false, tripleQuotes: true, hashComment: false)
        case .javascript:
            return Rules(keywords: set("function const let var if else return class extends import export from default for of in while switch case break continue new this typeof instanceof try catch finally throw async await yield null undefined true false interface type enum implements static void delete"),
                         lineComments: slash, blockComments: true, quotes: [quote, apostrophe], backtickMultiline: true, tripleQuotes: false, hashComment: false)
        case .python:
            return Rules(keywords: set("def class if elif else return import from as for in while try except finally raise with lambda pass break continue yield None True False and or not is global nonlocal async await del assert"),
                         lineComments: [], blockComments: false, quotes: [quote, apostrophe], backtickMultiline: false, tripleQuotes: true, hashComment: true)
        case .shell:
            return Rules(keywords: set("if then else elif fi for while until do done case esac function in return exit local export readonly set unset echo cd source true false"),
                         lineComments: [], blockComments: false, quotes: [quote, apostrophe], backtickMultiline: false, tripleQuotes: false, hashComment: true)
        case .ruby:
            return Rules(keywords: set("def end class module if elsif else unless while until for in do begin rescue ensure return yield require include self nil true false and or not then case when lambda proc"),
                         lineComments: [], blockComments: false, quotes: [quote, apostrophe], backtickMultiline: false, tripleQuotes: false, hashComment: true)
        case .go:
            return Rules(keywords: set("func var const type struct interface package import if else for range switch case default return go defer select chan map break continue fallthrough goto nil true false"),
                         lineComments: slash, blockComments: true, quotes: [quote, apostrophe], backtickMultiline: true, tripleQuotes: false, hashComment: false)
        case .rust:
            return Rules(keywords: set("fn let mut const static struct enum impl trait pub use mod crate self Self super if else match for while loop return break continue as in where async await move ref type unsafe dyn true false"),
                         lineComments: slash, blockComments: true, quotes: [quote], backtickMultiline: false, tripleQuotes: false, hashComment: false)
        case .cFamily:
            return Rules(keywords: set("if else for while do switch case default break continue return struct class enum union typedef static const void int char long short float double unsigned signed sizeof new delete this null NULL nullptr true false public private protected import package include define namespace using interface extends implements final abstract override fun val var"),
                         lineComments: slash, blockComments: true, quotes: [quote, apostrophe], backtickMultiline: false, tripleQuotes: false, hashComment: false)
        case .yaml:
            return Rules(keywords: set("true false null yes no on off True False Null"),
                         lineComments: [], blockComments: false, quotes: [quote, apostrophe], backtickMultiline: false, tripleQuotes: false, hashComment: true)
        case .json:
            return Rules(keywords: [], lineComments: [], blockComments: false, quotes: [quote], backtickMultiline: false, tripleQuotes: false, hashComment: false)
        }
    }

    private static func code(_ u: [UInt16], language: Language) -> [Token] {
        let rules = self.rules(for: language)
        let end = u.count
        var tokens: [Token] = []
        var i = 0
        var lineStart = true
        func add(_ from: Int, _ to: Int, _ kind: TokenKind) {
            tokens.append(Token(range: NSRange(location: from, length: to - from), kind: kind))
        }
        while i < end {
            let c = u[i]
            if c == newline {
                lineStart = true
                i += 1
                continue
            }
            if c == space || c == tab {
                i += 1
                continue
            }
            let atLineStart = lineStart
            lineStart = false
            // Comments.
            if rules.hashComment, c == hash, language != .shell || i == 0 || isSpace(u[i - 1]) {
                let stop = self.lineEnd(u, from: i, to: end)
                add(i, stop, .comment)
                i = stop
                continue
            }
            if c == slashU, i + 1 < end {
                if rules.lineComments.contains(where: { $0.count == 2 && $0[1] == u[i + 1] }), u[i + 1] == slashU {
                    let stop = self.lineEnd(u, from: i, to: end)
                    add(i, stop, .comment)
                    i = stop
                    continue
                }
                if rules.blockComments, u[i + 1] == star {
                    var stop = i + 2
                    while stop + 1 < end, !(u[stop] == star && u[stop + 1] == slashU) { stop += 1 }
                    stop = stop + 1 < end ? stop + 2 : end
                    add(i, stop, .comment)
                    i = stop
                    continue
                }
            }
            // Strings.
            if rules.quotes.contains(c) || (c == backtick && rules.backtickMultiline) {
                if rules.tripleQuotes, i + 2 < end, u[i + 1] == c, u[i + 2] == c {
                    var stop = i + 3
                    while stop + 2 < end, !(u[stop] == c && u[stop + 1] == c && u[stop + 2] == c) {
                        stop += u[stop] == backslash ? 2 : 1
                    }
                    stop = stop + 2 < end ? stop + 3 : end
                    add(i, min(stop, end), .string)
                    i = min(stop, end)
                    continue
                }
                // Apostrophes in Rust/Swift-style lifetimes and characters are not handled as strings.
                let stop = self.stringEnd(u, from: i + 1, to: end, quote: c, multiline: c == backtick)
                let isKey = language == .yaml && self.followedByColon(u, from: stop, to: end)
                add(i, stop, isKey ? .key : .string)
                i = stop
                continue
            }
            // Numbers.
            if isDigit(c), i == 0 || !isIdentifier(u[i - 1]) {
                let stop = self.numberEnd(u, from: i, to: end)
                add(i, stop, .number)
                i = stop
                continue
            }
            // Words.
            if isIdentifierStart(c) {
                var stop = i + 1
                while stop < end, isIdentifier(u[stop]) || (language == .yaml && (u[stop] == minus || u[stop] == dot)) { stop += 1 }
                if language == .yaml, atLineStart || self.onlyIndentBefore(u, i) || (i >= 2 && u[i - 1] == space && u[i - 2] == minus),
                   self.followedByColon(u, from: stop, to: end)
                {
                    add(i, stop, .key)
                } else if stop - i <= 12, let word = word(u, i, stop), rules.keywords.contains(word) {
                    add(i, stop, .keyword)
                }
                i = stop
                continue
            }
            i += 1
        }
        return tokens
    }

    // MARK: Scanning helpers

    /// End (exclusive) of a string whose opening quote is before `from`; stops at the closing quote or,
    /// for single-line strings, at the end of the line.
    private static func stringEnd(_ u: [UInt16], from: Int, to end: Int, quote: UInt16, multiline: Bool) -> Int {
        var i = from
        while i < end {
            let c = u[i]
            if c == backslash { i += 2; continue }
            if c == quote { return i + 1 }
            if c == newline, !multiline { return i }
            i += 1
        }
        return end
    }

    private static func numberEnd(_ u: [UInt16], from: Int, to end: Int) -> Int {
        var i = from
        if u[i] == minus { i += 1 }
        while i < end {
            let c = u[i]
            if isDigit(c) || isLetter(c) || c == dot || c == underscore {
                i += 1
            } else if (c == plus || c == minus), i > from, u[i - 1] == 0x65 || u[i - 1] == 0x45 {
                i += 1
            } else {
                break
            }
        }
        return max(i, from + 1)
    }

    private static func lineEnd(_ u: [UInt16], from: Int, to end: Int) -> Int {
        var i = from
        while i < end, u[i] != newline { i += 1 }
        return i
    }

    private static func followedByColon(_ u: [UInt16], from: Int, to end: Int) -> Bool {
        var i = from
        while i < end, u[i] == space || u[i] == tab { i += 1 }
        return i < end && u[i] == colon && (i + 1 == end || u[i + 1] == space || u[i + 1] == newline || u[i + 1] == tab)
    }

    private static func onlyIndentBefore(_ u: [UInt16], _ index: Int) -> Bool {
        var i = index - 1
        while i >= 0, u[i] == space || u[i] == tab { i -= 1 }
        return i < 0 || u[i] == newline
    }

    private static func word(_ u: [UInt16], _ from: Int, _ to: Int) -> String? {
        String(utf16CodeUnits: Array(u[from..<to]), count: to - from)
    }
}

private let newline: UInt16 = 0x0A
private let space: UInt16 = 0x20
private let tab: UInt16 = 0x09
private let quote: UInt16 = 0x22
private let apostrophe: UInt16 = 0x27
private let backtick: UInt16 = 0x60
private let backslash: UInt16 = 0x5C
private let colon: UInt16 = 0x3A
private let minus: UInt16 = 0x2D
private let plus: UInt16 = 0x2B
private let dot: UInt16 = 0x2E
private let hash: UInt16 = 0x23
private let slashU: UInt16 = 0x2F
private let star: UInt16 = 0x2A
private let underscore: UInt16 = 0x5F

private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
private func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
private func isLetter(_ c: UInt16) -> Bool { isLower(c) || (c >= 0x41 && c <= 0x5A) }
private func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == newline }
private func isIdentifierStart(_ c: UInt16) -> Bool { isLetter(c) || c == underscore || c == 0x24 }
private func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
