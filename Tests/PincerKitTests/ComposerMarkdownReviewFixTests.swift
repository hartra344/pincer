import Foundation
import Testing
@testable import PincerKit

/// #1067 round 1: Return in fences, verbatim code paste, link paste, outdent swallow.
@Suite("Composer markdown review fixes")
struct ComposerMarkdownReviewFixTests {
    private func ret(_ s: String, at i: Int) -> Bool {
        ComposerMarkdown.returnInsertsNewline(in: s as NSString, at: i)
    }

    @Test func returnInsideFences() {
        let t = "hi\n```swift\ncode\n```\nafter"
        #expect(!ret(t, at: 1))
        #expect(ret(t, at: 8))
        #expect(ret(t, at: 12))
        #expect(ret(t, at: 14))
        #expect(!ret(t, at: 17))
        #expect(!ret(t, at: 24))
        #expect(ret("```\nx", at: 5))
        #expect(ret("```", at: 3))
        #expect(!ret("", at: 0))
    }

    @Test func monospacedAttributedIsVerbatim() {
        let mono = NSAttributedString(string: "let x = 1", attributes: [NSAttributedString.Key("NSStrikethrough"): 0])
        #expect(RichTextToMarkdown.markdown(from: mono) == nil)
    }

    @Test func styleOnlyHTMLIsPlain() {
        #expect(RichTextToMarkdown.markdown(fromHTML: "<meta charset='utf-8'><div style=\"font-family:Menlo\"><span style=\"font-weight:bold\">let</span> x<br><span style=\"font-style:italic\">y</span></div>") == nil)
        #expect(RichTextToMarkdown.markdown(fromHTML: "<pre>a\nb</pre>") == nil)
        #expect(RichTextToMarkdown.markdown(fromHTML: "<p><font color=red>x</font></p>") == nil)
    }

    @Test func preMixedWithSemanticStillConverts() {
        let md = RichTextToMarkdown.markdown(fromHTML: "<h2>T</h2><pre>a\nb</pre>")
        #expect(md == "## T\n\n```\na\nb\n```")
        #expect(RichTextToMarkdown.markdown(fromHTML: "<p><b>x</b></p>") == "**x**")
    }

    @Test func pasteLink() {
        let t = "see the docs now" as NSString
        let sel = NSRange(location: 8, length: 4)
        let e = ComposerFormatting.pasteLink(" https://a.b/c \n", in: t, selection: sel)
        #expect(e?.replacement == "[docs](https://a.b/c)")
        #expect(e?.selection == NSRange(location: 8 + 21, length: 0))
        #expect(ComposerFormatting.pasteLink("mailto:a@b.c", in: t, selection: sel) != nil)
        #expect(ComposerFormatting.pasteLink("https://a.b", in: t, selection: NSRange(location: 8, length: 0)) == nil)
        #expect(ComposerFormatting.pasteLink("https://a.b x", in: t, selection: sel) == nil)
        #expect(ComposerFormatting.pasteLink("ftp://a.b", in: t, selection: sel) == nil)
        #expect(ComposerFormatting.pasteLink("hello", in: t, selection: sel) == nil)
        let code = "a `docs` b" as NSString
        #expect(ComposerFormatting.pasteLink("https://a.b", in: code, selection: NSRange(location: 3, length: 4)) == nil)
        let fenced = "```\ndocs\n```" as NSString
        #expect(ComposerFormatting.pasteLink("https://a.b", in: fenced, selection: NSRange(location: 4, length: 4)) == nil)
        let linked = "[docs](http://x)" as NSString
        #expect(ComposerFormatting.pasteLink("https://a.b", in: linked, selection: NSRange(location: 1, length: 4)) == nil)
    }

    @Test func outdentTopLevelIsNoOp() {
        let t = "- a" as NSString
        let sel = NSRange(location: 3, length: 0)
        let e = ComposerFormatting.indent(in: t, selection: sel, outdent: true)
        #expect(e == ComposerEdit(range: sel, replacement: "", selection: sel))
        #expect(ComposerFormatting.indent(in: "plain" as NSString, selection: sel, outdent: true) == nil)
    }
}
