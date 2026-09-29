import Foundation
import Testing
@testable import PincerKit

@Suite("Math source")
struct MathSourceTests {
    static let quadratic = #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#

    func wellFormed(_ svg: String) -> Bool {
        let parser = XMLParser(data: Data(svg.utf8))
        return parser.parse()
    }

    func box(_ latex: String) -> MathBox? {
        guard let doc = MathParser.parseDocument(latex) else { return nil }
        return MathLayout.layout(doc.node, .init(size: 17, base: 17, depth: 0, face: nil))
    }

    @Test func languageDetection() {
        for lang in ["math", "LaTeX", " tex ", "KaTeX"] { #expect(MathSource.isMath(language: lang)) }
        #expect(!MathSource.isMath(language: "mermaid"))
    }

    @Test func tokenizer() throws {
        let toks = try MathParser.tokenize(#"\frac{a}{b}^2 \\ x_1 & % comment"#)
        #expect(toks.first == .cmd("frac"))
        #expect(toks.contains(.rowsep))
        #expect(toks.contains(.caret))
        #expect(toks.contains(.underscore))
        #expect(toks.contains(.amp))
        #expect(!toks.contains(.char("c")))
    }

    @Test func parsesFractionAndScripts() throws {
        let doc = try #require(MathParser.parseDocument(#"\frac{1}{2} x^2_i"#))
        guard case .group(let items) = doc.node else { Issue.record("expected group"); return }
        #expect(items.count == 3 || items.count == 2)
        #expect(items.contains { if case .frac = $0 { true } else { false } })
        #expect(items.contains { if case .script(_, let sub, let sup) = $0 { sub != nil && sup != nil } else { false } })
    }

    @Test func stripsWrappers() {
        #expect(MathSource.svg(for: "$$x^2$$", theme: .light) == MathSource.svg(for: "x^2", theme: .light))
        #expect(MathSource.svg(for: #"\[x^2\]"#, theme: .light) == MathSource.svg(for: "x^2", theme: .light))
    }

    @Test func layoutSanity() throws {
        let line = try #require(box("x"))
        let frac = try #require(box(#"\frac{a}{b}"#))
        #expect(frac.asc + frac.desc > line.asc + line.desc)
        let sup = try #require(box("x^2"))
        let script = sup.prims.compactMap { p -> CGFloat? in
            if case .text(_, let y, let s, _, _, _) = p, s.contains("2") { return y } else { return nil }
        }
        #expect(script.first.map { $0 < 0 } == true)
        #expect(sup.asc > line.asc)
        let sub = try #require(box("x_i"))
        #expect(sub.desc > line.desc)
    }

    @Test func wellFormedOutputAcrossSamples() throws {
        let samples = [
            Self.quadratic, #"e^{i\pi} + 1 = 0"#, #"\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}"#,
            #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#, #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#,
            #"f(x)=\begin{cases} x & x\ge 0 \\ -x & \text{otherwise}\end{cases}"#,
            #"\left\{ \frac{a}{b} \right\rangle \hat{x} \vec{v} \overline{AB} \tilde{y} \ddot{z} \underline{u}"#,
            #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#, #"\binom{n}{k} \sqrt[3]{x} \mathbb{R} \mathbf{v} \operatorname{tr} A"#,
            "a < b, c > d", "x^2\ny^2",
        ]
        for tex in samples {
            for theme in RichRenderSVG.Theme.allCases {
                let svg = try #require(MathSource.svg(for: tex, theme: theme), "nil for \(tex)")
                #expect(wellFormed(svg), "malformed for \(tex)")
            }
        }
    }

    @Test func escaping() throws {
        let svg = try #require(MathSource.svg(for: "a < b", theme: .light))
        #expect(svg.contains("&lt;"))
        #expect(!svg.contains(">< "))
        #expect(wellFormed(svg))
    }

    @Test func rejectsBrokenInput() {
        #expect(MathSource.svg(for: #"\frac{a}{b"#, theme: .light) == nil)
        #expect(MathSource.svg(for: "a}", theme: .light) == nil)
        #expect(MathSource.svg(for: #"\left( x"#, theme: .light) == nil)
        #expect(MathSource.svg(for: #"\begin{cases} x"#, theme: .light) == nil)
        #expect(MathSource.svg(for: "   ", theme: .light) == nil)
        #expect(MathSource.svg(for: String(repeating: "x", count: 4_001), theme: .light) == nil)
        #expect(MathSource.svg(for: String(repeating: "x", count: 4_000), theme: .light) != nil)
    }

    @Test func unknownCommandRendersAsError() throws {
        let svg = try #require(MathSource.svg(for: #"x + \foobar y"#, theme: .light))
        #expect(svg.contains("\\foobar"))
        #expect(svg.contains("#CC0000"))
        #expect(wellFormed(svg))
    }

    @Test func deterministicAndThemed() throws {
        let a = try #require(MathSource.svg(for: Self.quadratic, theme: .light))
        #expect(a == MathSource.svg(for: Self.quadratic, theme: .light))
        let dark = try #require(MathSource.svg(for: Self.quadratic, theme: .dark))
        #expect(a != dark)
        #expect(a.contains(RichRenderSVG.palette(.light).text))
        #expect(!a.contains("<rect"))
    }

    @Test func matrixLaysOutGrid() throws {
        let m = try #require(box(#"\begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}"#))
        let one = try #require(box("1"))
        #expect(m.asc + m.desc > 2 * (one.asc + one.desc))
        #expect(m.w > 2 * one.w)
    }

    @Test func casesAndSumLimits() throws {
        let cases = try #require(box(#"\begin{cases} a & b \\ c & d \end{cases}"#))
        #expect(cases.asc + cases.desc > 30)
        let sum = try #require(box(#"\sum_{i=1}^{n} i"#))
        let plain = try #require(box(#"\sum i"#))
        #expect(sum.asc > plain.asc)
        #expect(sum.desc > plain.desc)
    }

    @Test func dumpForVisualCheck() throws {
        guard let dir = ProcessInfo.processInfo.environment["PINCER_MATH_DUMP"] else { return }
        let samples = ["quad": Self.quadratic, "gauss": #"\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}"#]
        for (name, tex) in samples {
            let svg = try #require(MathSource.svg(for: tex, theme: .light))
            try svg.write(toFile: "\(dir)/\(name).svg", atomically: true, encoding: .utf8)
        }
    }
}
