import Foundation
import Testing
@testable import PincerKit

/// #1069: numbered lists, quotes, headings, list renumbering, `~~~` fences and indented code in the composer.
@Suite("Composer Markdown nits")
struct ComposerMarkdownNitsTests {
    typealias F = ComposerFormattingTests

    static func run(_ marked: String, _ command: (NSString, NSRange) -> ComposerEdit) -> String {
        let (text, sel) = F.parse(marked)
        let r = F.apply(command(text as NSString, sel), to: text)
        return F.render(r.text, r.selection)
    }

    static func text(_ marked: String, _ command: (NSString, NSRange) -> ComposerEdit) -> String {
        let (text, sel) = F.parse(marked)
        return F.apply(command(text as NSString, sel), to: text).text
    }

    /// Replaces `range` in `text` the way a keystroke would, then runs the follow-up fix-up a text view runs.
    static func typed(_ text: String, replacing range: NSRange, with replacement: String) -> String {
        let pending = ComposerTextFixups.renumberRange(in: text as NSString, replacing: range, with: replacement)
        let after = (text as NSString).replacingCharacters(in: range, with: replacement)
        let caret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        guard let edit = ComposerTextFixups.edit(in: after as NSString, typedFenceAt: nil, renumber: pending, selection: caret)
        else { return after }
        return F.apply(edit, to: after).text
    }

    // MARK: toggles

    @Test func numberedListAddsRemovesAndConverts() {
        #expect(Self.text("[a\nb\nc]", ComposerFormatting.toggleNumberedList) == "1. a\n2. b\n3. c")
        #expect(Self.text("[1. a\n2. b]", ComposerFormatting.toggleNumberedList) == "a\nb")
        #expect(Self.text("[- a\n- b]", ComposerFormatting.toggleNumberedList) == "1. a\n2. b")
        #expect(Self.text("1. a\n2. b\n|c", ComposerFormatting.toggleNumberedList) == "1. a\n2. b\n3. c")
    }

    @Test func quoteAddsAndRemoves() {
        #expect(Self.text("[a\nb]", ComposerFormatting.toggleQuote) == "> a\n> b")
        #expect(Self.text("[> a\n> b]", ComposerFormatting.toggleQuote) == "a\nb")
        #expect(Self.text("[a\n\nb]", ComposerFormatting.toggleQuote) == "> a\n>\n> b")
        #expect(Self.text("[> > a]", ComposerFormatting.toggleQuote) == "> a")
    }

    @Test func headingAddsAndRemoves() {
        #expect(Self.run("|a", ComposerFormatting.toggleHeading) == "## |a")
        #expect(Self.text("## |a", ComposerFormatting.toggleHeading) == "a")
        #expect(Self.text("# |a", ComposerFormatting.toggleHeading) == "a")
    }

    // MARK: renumbering

    @Test func renumberFixesSiblingsAndKeepsTheStart() {
        func renumbered(_ text: String) -> String {
            let ns = text as NSString
            let all = NSRange(location: 0, length: 0)
            guard let edit = ComposerFormatting.renumber(in: ns, around: all, selection: all) else { return text }
            return F.apply(edit, to: text).text
        }
        #expect(renumbered("1. a\n3. b\n3. c") == "1. a\n2. b\n3. c")
        #expect(renumbered("3. a\n5. b") == "3. a\n4. b")
        #expect(renumbered("1. a\n   1. x\n   3. y\n3. b") == "1. a\n   1. x\n   2. y\n2. b")
        #expect(renumbered("1) a\n5) b") == "1) a\n2) b")
        #expect(renumbered("1. a\n\n3. b") == "1. a\n\n3. b")
        #expect(renumbered("```\n1. a\n3. b\n```") == "```\n1. a\n3. b\n```")
        #expect(ComposerFormatting.renumber(in: "1. a\n2. b", around: NSRange(location: 0, length: 0), selection: NSRange()) == nil)
    }

    @Test func deletingAnItemRenumbersTheRest() {
        let text = "1. a\n2. b\n3. c\n4. d"
        let line = (text as NSString).range(of: "2. b\n")
        #expect(Self.typed(text, replacing: line, with: "") == "1. a\n2. c\n3. d")
    }

    @Test func pastingLinesRenumbers() {
        let text = "1. a\n2. b"
        #expect(Self.typed(text, replacing: NSRange(location: 4, length: 0), with: "\n1. x") == "1. a\n2. x\n3. b")
    }

    @Test func typingWithoutLineBreaksDoesNotRenumber() {
        #expect(ComposerTextFixups.renumberRange(in: "1. a", replacing: NSRange(location: 4, length: 0), with: "b") == nil)
        #expect(ComposerTextFixups.renumberRange(in: "1. a\n", replacing: NSRange(location: 4, length: 1), with: "") != nil)
        #expect(ComposerTextFixups.renumberRange(in: "1. a", replacing: NSRange(location: 4, length: 0), with: "\n") != nil)
    }

    @Test func tabAndToggleRenumber() {
        #expect(F.indent("1. a\n2. b|\n3. c", outdent: false) == "1. a\n   1. b|\n2. c")
        #expect(Self.text("1. a\n|b\n2. c", ComposerFormatting.toggleNumberedList) == "1. a\n2. b\n3. c")
    }

    // MARK: tilde fences

    @Test func tildeFenceAutoCloses() {
        #expect(F.fence("~~~", typedAt: 2) == "~~~|\n~~~")
        let edit = ComposerTextFixups.edit(in: "~~~", typedFenceAt: 2, renumber: nil, selection: NSRange(location: 3, length: 0))
        #expect(edit != nil)
    }

    @Test func tildeFencesAreCode() {
        let text = "~~~\n**x**\n~~~\n**after**"
        let spans = ComposerMarkdown.tokenize(text)
        #expect(spans.filter { $0.kind == .codeFence }.count == 2)
        #expect(spans.filter { $0.kind == .strong }.count == 1)
        #expect(ComposerMarkdownIndex(text: text as NSString).isInsideCodeBlock(5))
    }

    @Test func fencesCloseOnlyOnTheSameMarkerAndLength() {
        let mixed = "~~~\n```\n**x**\n~~~\n**y**"
        let spans = ComposerMarkdown.tokenize(mixed)
        #expect(spans.filter { $0.kind == .codeFence }.count == 2)
        #expect(spans.filter { $0.kind == .strong }.count == 1)

        let longer = "````\n```\n**x**\n````\n**y**"
        #expect(ComposerMarkdown.tokenize(longer).filter { $0.kind == .strong }.count == 1)
        #expect(ComposerMarkdown.tokenize("```\n**x**\n```js\n**y**").filter { $0.kind == .strong }.isEmpty)
    }

    // MARK: indented code

    @Test func indentedCodeAfterABlankLine() {
        let text = "para\n\n    **x**\n\tlet y\nafter **z**"
        let spans = ComposerMarkdown.tokenize(text)
        #expect(spans.filter { $0.kind == .codeBlock }.count == 2)
        #expect(spans.filter { $0.kind == .strong }.count == 1)
        let index = ComposerMarkdownIndex(text: text as NSString)
        #expect(index.isInsideCodeBlock((text as NSString).range(of: "**x").location, in: text as NSString))
        #expect(!index.isInsideCodeBlock((text as NSString).range(of: "after").location, in: text as NSString))
    }

    @Test func indentedLinesThatAreNotCode() {
        // A paragraph continuation and an indented list item body stay Markdown.
        #expect(ComposerMarkdown.tokenize("para\n    **x**").filter { $0.kind == .codeBlock }.isEmpty)
        #expect(ComposerMarkdown.tokenize("- a\n\n    **x**").filter { $0.kind == .codeBlock }.isEmpty)
        #expect(ComposerMarkdown.tokenize("1. a\n\n    **x**").filter { $0.kind == .strong }.count == 1)
    }

    @Test func newlineInIndentedCodeDoesNotContinueAList() {
        #expect(F.newline("x\n\n    - a|") == nil)
    }

    // MARK: incremental index

    /// Random edits with fences of both kinds and indented lines. Besides the full re-tokenize, styling outside
    /// the range `update` returns must match the old styling (the styler only restyles that range).
    @Test func indexRestyleRangeCoversEveryChange() {
        var rng = SeededGenerator(seed: 1069)
        let pieces = ["```\n", "~~~\n", "````\n", "    ", "\t", "\n", "\n\n", "**", "x", "- ", "1. ", "> ", "# ", "~~", " "]
        var text = ("1. a\n~~~\ncode\n~~~\n\n    indented\n```\nb\n```\n" as NSString)
        var index = ComposerMarkdownIndex(text: text)
        for step in 0..<300 {
            let before = Self.kinds(text)
            let loc = ComposerMarkdownTests.safeBoundary(text, Int(rng.next() % UInt64(text.length + 1)))
            let end = ComposerMarkdownTests.safeBoundary(text, min(text.length, loc + Int(rng.next() % 4)))
            let insert = rng.next() % 4 == 0 ? "" : pieces[Int(rng.next() % UInt64(pieces.count))]
            let restyled = ComposerMarkdownTests.edit(&index, &text, at: loc, delete: end - loc, insert: insert)
            let after = Self.kinds(text)
            let full = Set(ComposerMarkdown.tokenize(text as String))
            #expect(full == Set(index.spans(in: text, range: NSRange(location: 0, length: text.length))), "step \(step)")
            let inserted = (insert as NSString).length
            var diverged: Int?
            for p in 0..<text.length where !NSLocationInRange(p, restyled) {
                guard p < loc || p >= loc + inserted else { continue }
                let old = p < loc ? p : p - inserted + (end - loc)
                if before[old] != after[p] { diverged = p; break }
            }
            #expect(diverged == nil, "step \(step): \(text.debugDescription) unstyled change at \(diverged ?? -1), restyled \(restyled)")
            if diverged != nil { return }
        }
    }

    /// The span kinds covering each UTF-16 unit.
    static func kinds(_ text: NSString) -> [Set<String>] {
        var out = [Set<String>](repeating: [], count: text.length)
        for span in ComposerMarkdown.tokenize(text as String) {
            for p in span.range.location..<min(NSMaxRange(span.range), text.length) { out[p].insert("\(span.kind)") }
        }
        return out
    }
}
