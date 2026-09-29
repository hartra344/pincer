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
}
