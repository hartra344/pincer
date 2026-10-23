import CoreText
import Foundation
import Testing
@testable import PincerKit

/// #1067: HTML / attributed-string paste conversion to Markdown.
@Suite("Rich text to Markdown")
struct RichTextToMarkdownTests {
    static func md(_ html: String) -> String? { RichTextToMarkdown.markdown(fromHTML: html) }

    @Test func inlineStyles() {
        #expect(Self.md("<p>a <strong>b</strong> <b>c</b></p>")?.contains("**b**") == true)
        #expect(Self.md("<b>c</b>")?.contains("**c**") == true)
        let em = Self.md("x <em>i</em> <i>j</i>")
        #expect(em?.contains("_i_") == true || em?.contains("*i*") == true)
        #expect(Self.md("<del>gone</del>")?.contains("~~gone~~") == true)
        #expect(Self.md("<s>gone</s>")?.contains("~~gone~~") == true)
        #expect(Self.md("<strike>gone</strike>")?.contains("~~gone~~") == true)
        #expect(Self.md("run <code>ls -la</code> now")?.contains("`ls -la`") == true)
    }

    @Test func linksAndHeadings() {
        #expect(Self.md("<a href=\"https://x.dev/a?b=1\">docs</a>")?.contains("[docs](https://x.dev/a?b=1)") == true)
        let h = Self.md("<h1>One</h1><h2>Two</h2><h3>Three</h3>") ?? ""
        #expect(h.contains("# One"))
        #expect(h.contains("## Two"))
        #expect(h.contains("### Three"))
        #expect(h.contains("\n"))
    }

    @Test func preBecomesFence() {
        let out = Self.md("<pre><code>let x = 1\nlet y = 2</code></pre>") ?? ""
        #expect(out.contains("```"))
        #expect(out.contains("let x = 1\nlet y = 2"))
    }

    @Test func lists() {
        let out = Self.md("<ul><li>a</li><li>b<ul><li>c</li></ul></li></ul>") ?? ""
        #expect(out.contains("- a"))
        #expect(out.contains("- b"))
        #expect(out.contains("  - c") || out.contains("    - c"))
        let ol = Self.md("<ol><li>x</li><li>y</li></ol>") ?? ""
        #expect(ol.contains("1. x"))
        #expect(ol.contains("2. y"))
    }

    @Test func blockquoteBreaksAndParagraphs() {
        #expect(Self.md("<blockquote>quoted</blockquote>")?.contains("> quoted") == true)
        let br = Self.md("<b>a</b><br>b") ?? ""
        #expect(br.contains("**a**\nb"))
        let p = Self.md("<p><b>one</b></p><p>two</p>") ?? ""
        #expect(p.contains("one") && p.contains("two"))
        #expect(p.contains("\n"))
    }

    @Test func entitiesDecoded() {
        let out = Self.md("<b>a</b> &amp; &lt;tag&gt; &quot;q&quot; &#39;s&#39; &nbsp;z &#x1F600;") ?? ""
        #expect(out.contains("& <tag> \"q\" 's'"))
        #expect(out.contains("😀"))
    }

    @Test func scriptStyleHeadDropped() {
        let out = Self.md("<html><head><title>T</title><style>b{}</style></head><body><script>alert(1)</script><b>ok</b></body></html>") ?? ""
        #expect(out.contains("**ok**"))
        #expect(!out.contains("alert"))
        #expect(!out.contains("b{}"))
        #expect(!out.contains("T\n") && !out.hasPrefix("T"))
    }

    @Test func formattingFreeHTMLReturnsNil() {
        #expect(Self.md("<span style=\"color:#d4d4d4;font-family:Menlo\">let</span><span> x</span>") == nil)
        #expect(Self.md("<meta charset='utf-8'><div><span>plain text</span></div>") == nil)
        #expect(Self.md("just text") == nil)
        #expect(Self.md("") == nil)
    }

    // MARK: attributed

    static func font(bold: Bool = false, italic: Bool = false, mono: Bool = false) -> CTFont {
        let base = CTFontCreateWithName((mono ? "Menlo" : "Helvetica") as CFString, 14, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if mono { traits.insert(.traitMonoSpace) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 14, nil, traits, traits) ?? base
    }

    static func attributed(_ parts: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, attrs) in parts { out.append(NSAttributedString(string: text, attributes: attrs)) }
        return out
    }

    @Test func attributedBoldItalicMono() {
        let s = Self.attributed([
            ("plain ", [.font: Self.font()]),
            ("bold", [.font: Self.font(bold: true)]),
            (" ", [.font: Self.font()]),
            ("ital", [.font: Self.font(italic: true)]),
            (" ", [.font: Self.font()]),
            ("mono", [.font: Self.font(mono: true)]),
        ])
        let out = RichTextToMarkdown.markdown(from: s) ?? ""
        #expect(out.contains("**bold**"))
        #expect(out.contains("_ital_") || out.contains("*ital*"))
        #expect(out.contains("`mono`"))
        #expect(out.hasPrefix("plain "))
    }

    @Test func attributedStrikeAndLink() {
        let s = Self.attributed([
            ("x ", [.font: Self.font()]),
            ("old", [.font: Self.font(), .strikethroughStyle: 1]),
            (" ", [.font: Self.font()]),
            ("site", [.font: Self.font(), .link: URL(string: "https://x.dev")!]),
        ])
        let out = RichTextToMarkdown.markdown(from: s) ?? ""
        #expect(out.contains("~~old~~"))
        #expect(out.contains("[site](https://x.dev"))
    }

    @Test func attributedWithoutFormattingIsNil() {
        let s = Self.attributed([("just ", [.font: Self.font()]), ("text", [.font: Self.font()])])
        #expect(RichTextToMarkdown.markdown(from: s) == nil)
        #expect(RichTextToMarkdown.markdown(from: NSAttributedString(string: "bare")) == nil)
        #expect(RichTextToMarkdown.markdown(from: NSAttributedString()) == nil)
    }
}
