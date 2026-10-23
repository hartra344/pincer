import Foundation
import Testing
@testable import PincerKit

/// #1067: pure composer editing commands (toggles, lists, newline continuation, fences).
@Suite("Composer formatting")
struct ComposerFormattingTests {
    /// Applies the edit and returns the resulting text and selection, checking the edit is in bounds.
    static func apply(_ edit: ComposerEdit, to text: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        #expect(edit.range.location >= 0 && NSMaxRange(edit.range) <= ns.length)
        let result = ns.replacingCharacters(in: edit.range, with: edit.replacement)
        let length = (result as NSString).length
        #expect(edit.selection.location >= 0 && NSMaxRange(edit.selection) <= length)
        return (result, edit.selection)
    }

    /// Text with `|` marking the caret, or `[` `]` marking a selection.
    static func parse(_ marked: String) -> (String, NSRange) {
        if !marked.contains("|"), let open = marked.firstIndex(of: "["), let close = marked.lastIndex(of: "]") {
            var s = marked
            s.remove(at: close)
            s.remove(at: open)
            let start = marked.utf16.distance(from: marked.utf16.startIndex, to: open.samePosition(in: marked.utf16)!)
            let end = marked.utf16.distance(from: marked.utf16.startIndex, to: close.samePosition(in: marked.utf16)!) - 1
            return (s, NSRange(location: start, length: end - start))
        }
        let caret = marked.firstIndex(of: "|")!
        var s = marked
        s.remove(at: caret)
        return (s, NSRange(location: marked.utf16.distance(from: marked.utf16.startIndex, to: caret.samePosition(in: marked.utf16)!), length: 0))
    }

    /// Renders text and selection back using the same marks.
    static func render(_ text: String, _ sel: NSRange) -> String {
        let ns = text as NSString
        if sel.length == 0 {
            return ns.substring(to: sel.location) + "|" + ns.substring(from: sel.location)
        }
        return ns.substring(to: sel.location) + "[" + ns.substring(with: sel) + "]" + ns.substring(from: NSMaxRange(sel))
    }

    static func toggled(_ style: ComposerInlineStyle, _ marked: String) -> String {
        let (text, sel) = parse(marked)
        let edit = ComposerFormatting.toggle(style, in: text as NSString, selection: sel)
        let r = apply(edit, to: text)
        return render(r.text, r.selection)
    }

    static func newline(_ marked: String) -> String? {
        let (text, sel) = parse(marked)
        guard let edit = ComposerFormatting.newline(in: text as NSString, selection: sel) else { return nil }
        let r = apply(edit, to: text)
        return render(r.text, r.selection)
    }

    static func indent(_ marked: String, outdent: Bool) -> String? {
        let (text, sel) = parse(marked)
        guard let edit = ComposerFormatting.indent(in: text as NSString, selection: sel, outdent: outdent) else { return nil }
        let r = apply(edit, to: text)
        return render(r.text, r.selection)
    }

    static func list(_ marked: String) -> String {
        let (text, sel) = parse(marked)
        let r = apply(ComposerFormatting.toggleList(in: text as NSString, selection: sel), to: text)
        return r.text
    }

    // MARK: inline toggles

    @Test func wrapAllStyles() {
        #expect(Self.toggled(.bold, "a [b] c") == "a **[b]** c")
        #expect(Self.toggled(.italic, "a [b] c") == "a _[b]_ c")
        #expect(Self.toggled(.inlineCode, "a [b] c") == "a `[b]` c")
        #expect(Self.toggled(.strikethrough, "a [b] c") == "a ~~[b]~~ c")
    }

    @Test func unwrapWhenMarkersOutsideSelection() {
        #expect(Self.toggled(.bold, "a **[b]** c") == "a [b] c")
        #expect(Self.toggled(.italic, "a _[b]_ c") == "a [b] c")
        #expect(Self.toggled(.italic, "a *[b]* c") == "a [b] c")
        #expect(Self.toggled(.inlineCode, "a `[b]` c") == "a [b] c")
        #expect(Self.toggled(.strikethrough, "a ~~[b]~~ c") == "a [b] c")
    }

    @Test func unwrapWhenSelectionIncludesMarkers() {
        let text = Self.toggled(.bold, "a [**b**] c")
        #expect(text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") == "a b c")
        let italic = Self.toggled(.italic, "a [_b_] c")
        #expect(italic.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") == "a b c")
    }

    @Test func emptySelectionInsertsPairAndCaretInMiddle() {
        #expect(Self.toggled(.bold, "a | b") == "a **|** b")
        #expect(Self.toggled(.italic, "a | b") == "a _|_ b")
        #expect(Self.toggled(.inlineCode, "a | b") == "a `|` b")
        #expect(Self.toggled(.strikethrough, "a | b") == "a ~~|~~ b")
    }

    @Test func emptySelectionInsideEmptyPairUnwraps() {
        #expect(Self.toggled(.bold, "a **|** b") == "a | b")
        #expect(Self.toggled(.inlineCode, "a `|` b") == "a | b")
    }

    @Test func wrapWithEmojiSelection() {
        #expect(Self.toggled(.bold, "x [😀你] y") == "x **[😀你]** y")
    }

    @Test func toggleTwiceRoundTrips() {
        let (text, sel) = Self.parse("one [two] three")
        let first = Self.apply(ComposerFormatting.toggle(.bold, in: text as NSString, selection: sel), to: text)
        let second = Self.apply(ComposerFormatting.toggle(.bold, in: first.text as NSString, selection: first.selection), to: first.text)
        #expect(second.text == text)
    }

    // MARK: links

    @Test func linkWrapSelectsUrlPlaceholder() {
        let (text, sel) = Self.parse("see [foo] now")
        let r = Self.apply(ComposerFormatting.toggleLink(in: text as NSString, selection: sel), to: text)
        #expect(r.text.hasPrefix("see [foo]("))
        #expect(r.text.hasSuffix(") now"))
        #expect(r.selection.length > 0)
        let selected = (r.text as NSString).substring(with: r.selection)
        #expect(r.text == "see [foo](\(selected)) now")
    }

    @Test func linkUnwrapFromInsideOrSelection() {
        let (text, caret) = Self.parse("see [fo|o](https://x.dev) now")
        let a = Self.apply(ComposerFormatting.toggleLink(in: text as NSString, selection: caret), to: text)
        #expect(a.text == "see foo now")
        let (text2, sel2) = Self.parse("see [[foo](https://x.dev)] now")
        let b = Self.apply(ComposerFormatting.toggleLink(in: text2 as NSString, selection: sel2), to: text2)
        #expect(b.text == "see foo now")
    }

    // MARK: lists

    @Test func toggleListAddsAndRemovesOnEveryLine() {
        #expect(Self.list("[a\nb\nc]") == "- a\n- b\n- c")
        #expect(Self.list("[- a\n- b\n- c]") == "a\nb\nc")
        #expect(Self.list("a\n[b\nc]\nd") == "a\n- b\n- c\nd")
        #expect(Self.list("[1. a\n2. b]") == "a\nb")
        #expect(Self.list("[a\n- b]") == "- a\n- b")
        #expect(Self.list("|x") == "- x")
    }

    // MARK: newline continuation

    @Test func continuesBullets() {
        #expect(Self.newline("- one|") == "- one\n- |")
        #expect(Self.newline("* one|") == "* one\n* |")
        #expect(Self.newline("+ one|") == "+ one\n+ |")
        #expect(Self.newline("  - one|") == "  - one\n  - |")
    }

    @Test func continuesNumbered() {
        #expect(Self.newline("1. one|") == "1. one\n2. |")
        #expect(Self.newline("9) one|") == "9) one\n10) |")
        #expect(Self.newline("3. x|") == "3. x\n4. |")
    }

    @Test func continuesTasksAsUnchecked() {
        #expect(Self.newline("- [ ] a|") == "- [ ] a\n- [ ] |")
        #expect(Self.newline("- [x] a|") == "- [ ] a\n- [ ] |".replacingOccurrences(of: "- [ ] a", with: "- [x] a"))
    }

    @Test func continuesQuotes() {
        #expect(Self.newline("> q|") == "> q\n> |")
        #expect(Self.newline("  > q|") == "  > q\n  > |")
    }

    @Test func midLineSplitMovesTailToNewItem() {
        #expect(Self.newline("- ab|cd") == "- ab\n- |cd")
    }

    @Test func emptyItemEndsList() {
        let marked = "- one\n- |"
        let (text, sel) = Self.parse(marked)
        let edit = ComposerFormatting.newline(in: text as NSString, selection: sel)
        #expect(edit != nil)
        if let edit {
            let r = Self.apply(edit, to: text)
            #expect(r.text == "- one\n" || r.text == "- one\n\n")
            #expect(r.selection.length == 0)
            #expect(r.selection.location == "- one\n".utf16.count)
        }
        #expect(Self.newline("1. |")?.hasPrefix("1.") == false)
    }

    @Test func plainLinesReturnNil() {
        #expect(Self.newline("hello|") == nil)
        #expect(Self.newline("|") == nil)
    }

    @Test func noContinuationInsideFence() {
        #expect(Self.newline("```\n- a|\n```") == nil)
    }

    // MARK: indent

    @Test func indentAndOutdent() {
        #expect(Self.indent("- a|", outdent: false) == "  - a|")
        #expect(Self.indent("1. a|", outdent: false) == "   1. a|")
        #expect(Self.indent("  - a|", outdent: true) == "- a|")
        #expect(Self.indent("   1. a|", outdent: true) == "1. a|")
        #expect(Self.indent("- a|", outdent: true) == "- a|" || Self.indent("- a|", outdent: true) == nil)
    }

    @Test func indentNilOffListLines() {
        #expect(Self.indent("hello|", outdent: false) == nil)
        #expect(Self.indent("hello|", outdent: true) == nil)
    }

    // MARK: fences

    static func fence(_ text: String, typedAt location: Int) -> String? {
        guard let edit = ComposerFormatting.autoCloseFence(in: text as NSString, typedAt: location) else { return nil }
        let r = apply(edit, to: text)
        return render(r.text, r.selection)
    }

    @Test func autoClosesOpeningFence() {
        let out = Self.fence("```", typedAt: 2)
        #expect(out == "```|\n```")
    }

    @Test func autoCloseKeepsFollowingText() {
        let out = Self.fence("a\n```\nb", typedAt: 4)
        #expect(out == "a\n```|\n```\nb")
    }

    @Test func doesNotAutoCloseClosingFence() {
        #expect(Self.fence("```\ncode\n```", typedAt: 11) == nil)
    }

    @Test func doesNotAutoCloseWhenAlreadyClosedBelow() {
        #expect(Self.fence("```\ncode\n```", typedAt: 2) == nil)
    }

    @Test func doesNotAutoCloseNonFenceLines() {
        #expect(Self.fence("x ```", typedAt: 4) == nil)
        #expect(Self.fence("``", typedAt: 1) == nil)
    }
}
