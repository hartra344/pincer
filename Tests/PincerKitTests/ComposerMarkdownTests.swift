import Foundation
import Testing
@testable import PincerKit

/// #1067: the composer's Markdown tokenizer and incremental fence index.
@Suite("Composer Markdown tokenizer")
struct ComposerMarkdownTests {
    typealias Kind = ComposerMarkdownKind

    static func spans(_ text: String, _ kind: Kind) -> [ComposerMarkdownSpan] {
        ComposerMarkdown.tokenize(text).filter { $0.kind == kind }
    }

    static func slice(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    static func markers(_ text: String, _ span: ComposerMarkdownSpan) -> [String] {
        span.markerRanges.map { slice(text, $0) }
    }

    @Test func strongAndEmphasis() {
        let text = "a **bold** and _it_ and *it2* and __b2__"
        let strong = Self.spans(text, .strong)
        #expect(strong.map { Self.slice(text, $0.range) } == ["**bold**", "__b2__"])
        #expect(strong.map { Self.slice(text, $0.contentRange) } == ["bold", "b2"])
        #expect(Self.markers(text, strong[0]).joined() == "****")
        let em = Self.spans(text, .emphasis)
        #expect(em.map { Self.slice(text, $0.range) } == ["_it_", "*it2*"])
        #expect(em.map { Self.slice(text, $0.contentRange) } == ["it", "it2"])
    }

    @Test func strikethroughAndInlineCode() {
        let text = "~~gone~~ and `code` and ``a`b``"
        let strike = Self.spans(text, .strikethrough)
        #expect(strike.count == 1)
        #expect(Self.slice(text, strike[0].range) == "~~gone~~")
        #expect(Self.slice(text, strike[0].contentRange) == "gone")
        let code = Self.spans(text, .inlineCode)
        #expect(code.map { Self.slice(text, $0.contentRange) } == ["code", "a`b"])
        #expect(Self.slice(text, code[0].range) == "`code`")
    }

    @Test func tripleStarIsStrongAndEmphasis() {
        let text = "***both***"
        let kinds = Set(ComposerMarkdown.tokenize(text).map(\.kind))
        #expect(kinds.contains(.strong) && kinds.contains(.emphasis))
        #expect(ComposerMarkdown.tokenize(text).count == 2)
    }

    @Test func linkRanges() {
        let text = "see [the docs](https://x.dev/a) now"
        let links = Self.spans(text, .link)
        #expect(links.count == 1)
        let link = links[0]
        #expect(Self.slice(text, link.range) == "[the docs](https://x.dev/a)")
        #expect(Self.slice(text, link.contentRange) == "the docs")
        #expect(Self.markers(text, link) == ["[", "](", "https://x.dev/a", ")"])
    }

    @Test func headings() {
        let text = "# One\n### Three\n####### seven\n#nospace"
        let headings = ComposerMarkdown.tokenize(text).filter { if case .heading = $0.kind { true } else { false } }
        #expect(headings.map(\.kind) == [.heading(1), .heading(3)])
        #expect(Self.markers(text, headings[0]) == ["# "])
        #expect(Self.markers(text, headings[1]) == ["### "])
        #expect(Self.slice(text, headings[0].contentRange) == "One")
    }

    @Test func listItemsAndQuotes() {
        let text = "- a\n* b\n+ c\n1. d\n2) e\n  - f\n- [ ] g\n- [x] h\n> q"
        let items = Self.spans(text, .listItem)
        #expect(items.count == 8)
        let m = items.map { Self.markers(text, $0).joined() }
        #expect(m[0] == "- " && m[1] == "* " && m[2] == "+ " && m[3] == "1. " && m[4] == "2) ")
        #expect(m[5].trimmingCharacters(in: .whitespaces) == "-")
        #expect(m[6] == "- [ ] " && m[7] == "- [x] ")
        let quote = Self.spans(text, .blockquote)
        #expect(quote.count == 1)
        #expect(Self.markers(text, quote[0]) == ["> "])
    }

    @Test func utf16RangesWithEmojiAndCJK() {
        let text = "😀 **你好** 👨‍👩‍👧 `é` _x_"
        let ns = text as NSString
        let strong = Self.spans(text, .strong)
        #expect(strong.count == 1)
        #expect(ns.substring(with: strong[0].range) == "**你好**")
        #expect(ns.substring(with: strong[0].contentRange) == "你好")
        #expect(ns.substring(with: Self.spans(text, .inlineCode)[0].contentRange) == "é")
        #expect(ns.substring(with: Self.spans(text, .emphasis)[0].contentRange) == "x")
        for span in ComposerMarkdown.tokenize(text) {
            #expect(NSMaxRange(span.range) <= ns.length)
        }
    }

    @Test func backslashEscapesDisableMarkers() {
        #expect(ComposerMarkdown.tokenize("\\*not em\\*").isEmpty)
        #expect(ComposerMarkdown.tokenize("\\**x**").filter { $0.kind == .strong }.isEmpty)
        #expect(ComposerMarkdown.tokenize("\\`not code\\`").isEmpty)
    }

    @Test func intrawordUnderscoreIsNotEmphasis() {
        #expect(ComposerMarkdown.tokenize("snake_case_name and my_var_x").isEmpty)
        #expect(Self.spans("a _real_ one", .emphasis).count == 1)
    }

    @Test func unclosedMarkersProduceNoSpan() {
        #expect(ComposerMarkdown.tokenize("**open and `tick and ~~no and [link](x").isEmpty)
        #expect(ComposerMarkdown.tokenize("a * b * c").isEmpty)
    }

    @Test func inlineMarkersNeverCrossBlankLines() {
        #expect(ComposerMarkdown.tokenize("**a\n\nb**").isEmpty)
    }

    @Test func codeSpansSuppressInlineStyling() {
        let text = "`**not bold** _x_` and **bold**"
        let spans = ComposerMarkdown.tokenize(text)
        #expect(spans.filter { $0.kind == .strong }.count == 1)
        #expect(spans.filter { $0.kind == .emphasis }.isEmpty)
        #expect(spans.filter { $0.kind == .inlineCode }.count == 1)
    }

    @Test func fencesAndCodeBlockLines() {
        let text = "before\n```swift\nlet **x** = 1\n- item\n```\n**after**"
        let spans = ComposerMarkdown.tokenize(text)
        let fences = spans.filter { $0.kind == .codeFence }.map { Self.slice(text, $0.range) }
        #expect(fences.count == 2)
        #expect(fences[0].hasPrefix("```swift"))
        let block = spans.filter { $0.kind == .codeBlock }.map { Self.slice(text, $0.range) }
        #expect(block == ["let **x** = 1", "- item"] || block == ["let **x** = 1\n", "- item\n"])
        #expect(spans.filter { $0.kind == .strong }.count == 1)
        #expect(spans.filter { $0.kind == .listItem }.isEmpty)
        #expect(Self.slice(text, spans.first { $0.kind == .strong }!.contentRange) == "after")
    }

    @Test func unclosedFenceRunsToEnd() {
        let text = "```\nline **a**\nmore"
        let spans = ComposerMarkdown.tokenize(text)
        #expect(spans.filter { $0.kind == .codeBlock }.count == 2)
        #expect(spans.filter { $0.kind == .strong }.isEmpty)
    }

    @Test func paragraphRange() {
        let text = "one\ntwo\nthree" as NSString
        let r = ComposerMarkdown.paragraphRange(in: text, covering: NSRange(location: 5, length: 0))
        #expect(text.substring(with: r).hasPrefix("two"))
        #expect(r.location == 4)
        let multi = ComposerMarkdown.paragraphRange(in: text, covering: NSRange(location: 2, length: 4))
        #expect(multi.location == 0 && NSMaxRange(multi) >= 8)
        let empty = ComposerMarkdown.paragraphRange(in: "" as NSString, covering: NSRange(location: 0, length: 0))
        #expect(empty.length == 0)
    }

    // MARK: Index

    @Test func isInsideCodeBlock() {
        let text = "a\n```\ncode\n```\nb" as NSString
        let index = ComposerMarkdownIndex(text: text)
        #expect(!index.isInsideCodeBlock(0))
        #expect(index.isInsideCodeBlock(text.range(of: "code").location))
        #expect(!index.isInsideCodeBlock(text.range(of: "b", options: .backwards).location))
    }

    /// Applies an edit to `text` and runs the index update the way a text-storage delegate would.
    static func edit(_ index: inout ComposerMarkdownIndex, _ text: inout NSString, at location: Int, delete: Int, insert: String) -> NSRange {
        text = text.replacingCharacters(in: NSRange(location: location, length: delete), with: insert) as NSString
        let edited = NSRange(location: location, length: (insert as NSString).length)
        return index.update(text: text, editedRange: edited, changeInLength: edited.length - delete)
    }

    @Test func ordinaryEditReturnsOnlyEditedParagraph() {
        var text = ("line one **a**\nline two\nline three\n" as NSString)
        var index = ComposerMarkdownIndex(text: text)
        let range = Self.edit(&index, &text, at: 18, delete: 0, insert: "x")
        let para = ComposerMarkdown.paragraphRange(in: text, covering: NSRange(location: 18, length: 1))
        #expect(NSEqualRanges(range, para) || (NSLocationInRange(18, range) && range.length <= para.length + 1))
        #expect(range.length < text.length)
    }

    @Test func addingAndRemovingFenceExtendsRange() {
        var text = ("a\nb\nc\nd\n" as NSString)
        var index = ComposerMarkdownIndex(text: text)
        let added = Self.edit(&index, &text, at: 2, delete: 0, insert: "```\n")
        #expect(NSMaxRange(added) == text.length || NSMaxRange(added) >= text.length - 1)
        #expect(index.isInsideCodeBlock(text.range(of: "c").location))
        let removed = Self.edit(&index, &text, at: 2, delete: 4, insert: "")
        #expect(NSMaxRange(removed) >= text.length - 1)
        #expect(!index.isInsideCodeBlock(text.range(of: "c").location))
    }

    @Test func indexMatchesFullTokenizeAfterRandomEdits() {
        var rng = SeededGenerator(seed: 1067)
        let pieces = ["**", "_", "`", "```\n", "\n", "~~", "[a](b)", "- ", "> ", "# ", "x", "é", "😀", " ", "1. ", "\\", "\n\n"]
        var text = ("# T\n- a **b**\n```\ncode\n```\n> q _e_\n" as NSString)
        var index = ComposerMarkdownIndex(text: text)
        for step in 0..<200 {
            let location = Int(rng.next() % UInt64(text.length + 1))
            let maxDelete = min(3, text.length - location)
            let delete = Int(rng.next() % UInt64(maxDelete + 1))
            var insert = pieces[Int(rng.next() % UInt64(pieces.count))]
            if rng.next() % 4 == 0 { insert = "" }
            // Keep edits off the middle of surrogate pairs and CRLF-free.
            let loc = Self.safeBoundary(text, location)
            let end = Self.safeBoundary(text, min(text.length, loc + delete))
            _ = Self.edit(&index, &text, at: loc, delete: end - loc, insert: insert)
            let full = Set(ComposerMarkdown.tokenize(text as String))
            let incremental = Set(index.spans(in: text, range: NSRange(location: 0, length: text.length)))
            #expect(full == incremental, "step \(step) diverged for \(text.debugDescription)")
            if full != incremental { return }
        }
    }

    static func safeBoundary(_ text: NSString, _ location: Int) -> Int {
        guard location > 0, location < text.length else { return location }
        let r = text.rangeOfComposedCharacterSequence(at: location)
        return r.location
    }
}

struct SeededGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
