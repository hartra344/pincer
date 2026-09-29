import CoreGraphics
import Foundation
import Testing
@testable import PincerKit

@Suite struct InlineMathTests {
    private func latex(_ text: String) -> [String] { InlineMath.spans(in: text).map(\.latex) }

    @Test func findsDollarAndParenSpans() {
        #expect(self.latex("Energy is $E = mc^2$, roughly.") == ["E = mc^2"])
        #expect(self.latex(#"Area \(\pi r^2\) and $a_i$."#) == [#"\pi r^2"#, "a_i"])
        #expect(self.latex("($x$)") == ["x"])
    }

    @Test func leavesPricesAndShellAlone() {
        #expect(self.latex("It costs $5 and $10 later.").isEmpty)
        #expect(self.latex("Pay $5-$10 today.").isEmpty)
        #expect(self.latex("US$5 is fine").isEmpty)
        #expect(self.latex("Use $HOME/$USER here.").isEmpty)
        #expect(self.latex("echo $PATH").isEmpty)
        #expect(self.latex("A $ x$ gap").isEmpty)
        #expect(self.latex("Escaped \\$x$ stays").isEmpty)
        #expect(self.latex("between $5 and $x$ done") == ["x"])
    }

    @Test func skipsCodeSpansAndDisplayMath() {
        #expect(self.latex("Run `echo $a$` now").isEmpty)
        #expect(self.latex("Run ``a `$x$` b`` now").isEmpty)
        #expect(self.latex("Block $$x^2$$ here").isEmpty)
        #expect(self.latex("No\n$x\ny$ newline").isEmpty)
    }

    @Test func rendersOnTheBaseline() throws {
        let color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let simple = try #require(InlineMath.render("x^2 + y_i", fontSize: 15, color: color, scale: 2))
        #expect(simple.size.width > 20)
        #expect(simple.size.height < 40)
        #expect(simple.descent > 0 && simple.descent < simple.size.height)
        #expect(simple.image.width == Int(ceil(simple.size.width * 2)))
        // Text style keeps big operators and fractions compact.
        let sum = try #require(InlineMath.render(#"\sum_{i=1}^n \frac{a}{b}"#, fontSize: 15, color: color, scale: 1))
        let display = try #require(MathSource.svg(for: #"\sum_{i=1}^n \frac{a}{b}"#, theme: .light))
        let displayHeight = try #require(SVGSource.intrinsicSize(Data(display.utf8))).height
        #expect(sum.size.height < displayHeight)
    }

    @Test func unknownOrBrokenStaysAsText() {
        let color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        #expect(InlineMath.render(#"\notacommand x"#, fontSize: 15, color: color, scale: 1) == nil)
        #expect(InlineMath.render("{x", fontSize: 15, color: color, scale: 1) == nil)
        #expect(!InlineMath.isDrawable(#"\notacommand"#))
    }

    @Test func plainTextMatchesTheDrawnText() {
        #expect(InlineMath.plainText("Area is $\\pi r^2$ **big**") == "Area is \u{FFFC} big")
        #expect(InlineMath.plainText("Keep $\\nope$ here") == "Keep $\\nope$ here")
        #expect(InlineMath.plainText("Price $5 and $10") == "Price $5 and $10")
        // Emphasis markers inside math don't leak into the surrounding text.
        #expect(InlineMath.plainText("$a*b$ and *c*") == "\u{FFFC} and c")
        #expect(TranscriptSearch.renderedTexts(markdown: "Area is $\\pi r^2$.") == ["Area is \u{FFFC}."])
    }
}
