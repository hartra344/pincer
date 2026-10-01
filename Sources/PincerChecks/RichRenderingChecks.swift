import CoreGraphics
import Foundation
import PincerKit

// Rich rendering (issue #40): display math parsed out of Markdown, fenced Mermaid and math drawn
// natively as SVG, Find skipping their source, and the demo's "Rate limiter design" chat.

@MainActor
func runRichRenderingChecks() {
    let blocks = MarkdownBlock.parse("Before\n\n$$\nx^2 + y^2 = z^2\n$$\n\nAfter $$ inline $$ text\n$$ e^{i\\pi} + 1 = 0 $$\n\\[\n\\frac{a}{b}\n\\]")
    let math = blocks.compactMap { block -> String? in
        if case let .code(language, code) = block, language == "math" { return code }
        return nil
    }
    check(math == ["x^2 + y^2 = z^2", "e^{i\\pi} + 1 = 0", "\\frac{a}{b}"],
          "$$ … $$, one-line $$ … $$ and \\[ … \\] are display math; mid-line $$ is text (\(math))")
    check(blocks.contains(.paragraph("After $$ inline $$ text")), "mid-paragraph $$ stays text")
    check(MarkdownBlock.parse("$$\na\n\nb\n$$") == [.code("math", "a\n\nb")], "a blank line inside $$ doesn't end the block")

    // Inline math: $…$ and \(…\), but prices, shell variables and code spans stay text.
    let inline = InlineMath.spans(in: "Area $\\pi r^2$ and \\(a_i\\), but $5 and $10, $HOME/$USER and `$x$`").map(\.latex)
    check(inline == ["\\pi r^2", "a_i"], "inline $…$ and \\(…\\) found; prices, shell and code skipped (\(inline))")
    let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    check(InlineMath.render("x^2", fontSize: 15, color: black, scale: 2) != nil, "inline math draws natively")
    check(InlineMath.render("\\nope x", fontSize: 15, color: black, scale: 2) == nil, "inline math with an unknown command stays text")
    check(TranscriptSearch.renderedTexts(markdown: "Area $\\pi r^2$ here") == ["Area \u{FFFC} here"],
          "Find skips drawn inline math source")

    // Quick Look previews: non-text attachments, written as one safe file name under a private folder.
    check(FilePreviewFiles.isPreviewable(FileRef(name: "a.pdf", artifactId: "x", mimeType: "application/pdf"))
          && !FilePreviewFiles.isPreviewable(FileRef(name: "a.sh", artifactId: "x", mimeType: "text/x-shellscript")),
          "PDFs open in Quick Look; text files expand inline instead")
    check(FilePreviewFiles.fileName("../../etc/passwd", mimeType: nil) == "passwd"
          && FilePreviewFiles.fileName("summary", mimeType: "application/pdf") == "summary.pdf",
          "Quick Look file names can't leave their folder and get an extension from the MIME type")

    // Streaming cuts never land inside display math, so the chunks parse to the same blocks.
    let long = String(repeating: "Some words here. ", count: 80)
    let streamed = "\(long)\n\n$$\n\\sum_i x_i\n\n\\int f\n$$\n\n\(long)\n\nEnd"
    let cuts = MarkdownBlock.streamingFreezePoints(streamed, minimumChunk: 16)
    var start = streamed.startIndex
    var chunked: [MarkdownBlock] = []
    for cut in cuts + [streamed.endIndex] {
        chunked += MarkdownBlock.parse(String(streamed[start..<cut]))
        start = cut
    }
    check(chunked == MarkdownBlock.parse(streamed), "freeze points keep display math whole (\(cuts.count) cuts)")

    check(MermaidSource.isMermaid(language: "mermaid") && MermaidSource.isMermaid(language: " Mermaid ")
          && !MermaidSource.isMermaid(language: "swift"), "```mermaid is recognized")
    check(MathSource.isMath(language: "math") && MathSource.isMath(language: "latex") && !MathSource.isMath(language: "swift"),
          "```math and ```latex are recognized")
    let flowchart = "flowchart TD\n    A[Request arrives] --> B{Tokens left?}\n    B -->|Yes| C[Take a token]\n    B -->|No| E[Return 429]\n    E -.-> A"
    let sequence = "sequenceDiagram\n    participant C as Client\n    participant L as Limiter\n    C->>L: GET /orders\n    alt empty\n        L-->>C: 429\n    end"
    let formula = #"T(t) = \min\left(b,\; T_0 + r\,(t - t_0)\right)"#
    for theme in RichRenderSVG.Theme.allCases {
        for (label, svg) in [
            ("flowchart", MermaidSource.svg(for: flowchart, theme: theme)),
            ("sequence", MermaidSource.svg(for: sequence, theme: theme)),
            ("math", MathSource.svg(for: formula, theme: theme)),
        ] {
            let data = svg.map { Data($0.utf8) }
            check(data.map(SVGSource.isSVG) == true && data.flatMap(SVGSource.intrinsicSize) != nil
                  && data.map { XMLParser(data: $0).parse() } == true,
                  "\(label) (\(theme)) renders to well-formed, sized SVG")
        }
    }
    check(MermaidSource.svg(for: "gantt\n  title Plan\n  section A\n  Task :a1, 2024-01-01, 3d", theme: .light) == nil,
          "unsupported Mermaid diagrams stay code")
    check(MathSource.svg(for: "\\frac{a}{b", theme: .light) == nil, "unbalanced math stays code")

    let entries = TranscriptBuilder.build([ChatItem(json(#"""
    {"role":"assistant","content":"Flow:\n\n```mermaid\ngraph TD\n  A[Queue] --> B[Worker]\n```\n\n$$\nQueue + 1\n$$\n\nQueue depth","__openclaw":{"id":"r1"}}
    """#), fallbackIndex: 0)!])
    check(TranscriptSearch.matches("Queue", in: entries).count == 1, "Find skips diagram and math source, which is drawn")
}

private let richRenderingKey = "agent:main:dashboard:rate-limiter"

@MainActor
func runDemoRichRendering() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("demo for rich rendering", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo connected")
    guard connected else { return }
    check(gateway.sessions[richRenderingKey] != nil, "demo has the Rate limiter design chat")
    let chat = gateway.chat(for: richRenderingKey)
    await chat.load()
    func text() -> String {
        var parts: [String] = []
        for case let .assistant(turn) in chat.entries { parts += turn.text }
        return parts.joined(separator: "\n")
    }
    let loaded = await waitFor("rate limiter history") { text().contains("```mermaid") }
    let blocks = MarkdownBlock.parse(text())
    var diagrams = 0, formulas = 0
    for case let .code(language, code) in blocks {
        if MermaidSource.isMermaid(language: language ?? ""), MermaidSource.svg(for: code, theme: .dark) != nil { diagrams += 1 }
        if MathSource.isMath(language: language ?? ""), MathSource.svg(for: code, theme: .dark) != nil { formulas += 1 }
    }
    check(loaded && diagrams == 2 && formulas == 2,
          "demo chat draws 2 Mermaid diagrams and 2 formulas (got \(diagrams), \(formulas))")
    // #264's native header test covers theme redraw and Copy/Copied state. Keep its visible
    // demo counterpart available with an intact fenced HTML payload for both Copy and Preview.
    let html = blocks.compactMap { block -> String? in
        if case let .code(language, source) = block, language?.lowercased() == "html" { return source }
        return nil
    }
    check(html.count == 1 && html[0].contains("<div style=") && html[0].contains("Slow down a little")
          && html[0].contains("</div>"), "demo retains the complete HTML code card for Copy and Preview (#264)")
    var inline = 0
    for case let .paragraph(paragraph) in blocks {
        inline += InlineMath.spans(in: paragraph).filter { InlineMath.isDrawable($0.latex) }.count
    }
    check(inline == 4, "demo chat draws 4 inline formulas (got \(inline))")
    var files: [FileRef] = []
    for case let .assistant(turn) in chat.entries { files += turn.files }
    let pdf = files.first { $0.mimeType == "application/pdf" }
    check(pdf.map(FilePreviewFiles.isPreviewable) == true, "demo chat attaches a PDF that opens in Quick Look")
    if let pdf {
        let data = await gateway.files.data(for: pdf, sessionKey: richRenderingKey)
        check(data?.prefix(5) == Data("%PDF-".utf8), "demo PDF downloads as a PDF (\(data?.count ?? 0) bytes)")
        if let data {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PincerChecksQuickLook")
            let url = try? FilePreviewFiles.write(data, name: pdf.name, mimeType: pdf.mimeType, in: root)
            check(url?.lastPathComponent == "rate-limiter-design.pdf", "demo PDF is written for Quick Look under its own name")
            FilePreviewFiles.clear(in: root)
        }
    }
}
