import Foundation
import Testing
@testable import PincerKit

/// Issue #40: native Mermaid rendering.
@Suite("Mermaid source")
struct MermaidSourceTests {
    func chart(_ body: String) -> MermaidFlowchart {
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return MermaidFlowchart.parse(header: lines[0], lines: Array(lines.dropFirst()))!
    }

    func wellFormed(_ svg: String) -> Bool {
        let parser = XMLParser(data: Data(svg.utf8))
        return parser.parse()
    }

    @Test func languageDetection() {
        #expect(MermaidSource.isMermaid(language: " Mermaid "))
        #expect(!MermaidSource.isMermaid(language: "swift"))
    }

    @Test func parsesShapesAndLabels() {
        let c = chart("""
        graph LR
        A[Rect] --> B(Round)
        B --> C{Decide}
        C --> D((Circle)) --> E[(DB)]
        F{{Hex}} --> G[/Para/] --> H([Stad])
        I[[Sub]] --> J>Asym]
        """)
        #expect(c.direction == "LR")
        let shapes = c.nodes.map(\.shape)
        #expect(shapes == [.rect, .round, .diamond, .circle, .cylinder, .hexagon, .para, .stadium, .subroutine, .asym])
        #expect(c.nodes[0].label == "Rect")
        #expect(c.edges.count == 7)
    }

    @Test func parsesEdgeVariantsAndLabels() {
        let c = chart("""
        flowchart TD
        A -->|yes| B
        A -- no --> C
        B -.-> D
        B -. maybe .-> E
        C ==> D
        C --o E
        D --x E
        E <--> A
        A --- B
        """)
        #expect(c.direction == "TD")
        #expect(c.edges[0].label == "yes")
        #expect(c.edges[1].label == "no")
        #expect(c.edges[2].style == .dotted && c.edges[2].head == .arrow)
        #expect(c.edges[3].label == "maybe" && c.edges[3].style == .dotted)
        #expect(c.edges[4].style == .thick)
        #expect(c.edges[5].head == .circle)
        #expect(c.edges[6].head == .cross)
        #expect(c.edges[7].tail == .arrow && c.edges[7].head == .arrow)
        #expect(c.edges[8].head == .none)
    }

    @Test func parsesChainsGroupsAndIgnoredLines() {
        let c = chart("""
        graph TB
        %% comment
        classDef foo fill:#f9f
        A & B --> C --> D; D --> E
        class A foo
        style B fill:#fff
        A:::foo --> Z
        """)
        #expect(c.nodes.map(\.id) == ["A", "B", "C", "D", "E", "Z"])
        #expect(c.edges.count == 5)
    }

    @Test func parsesSubgraphsAndQuotedLabels() {
        let c = chart("""
        graph TD
        subgraph one [First group]
        A["Say <br/> hi"] --> B
        end
        B --> C
        """)
        #expect(c.subgraphs.count == 1 && c.subgraphs[0].title == "First group")
        #expect(c.nodes[0].subgraph == 0 && c.nodes[2].subgraph == nil)
        #expect(c.nodes[0].label == "Say <br/> hi".replacingOccurrences(of: "<br/>", with: "\n"))
    }

    @Test func layoutRanksIncreaseAndNodesDoNotOverlap() {
        let c = chart("""
        graph TD
        A --> B
        A --> C
        B --> D
        C --> D
        D --> E
        A --> E
        """)
        let layout = c.layout()
        for edge in c.edges {
            #expect(layout.rects[edge.from].midY < layout.rects[edge.to].midY)
        }
        for i in layout.rects.indices {
            for j in layout.rects.indices where j > i {
                #expect(!layout.rects[i].intersects(layout.rects[j]))
            }
        }
    }

    @Test func cyclesAndSelfLoopsRender() throws {
        let svg = try #require(MermaidSource.svg(for: "graph LR\nA --> B\nB --> C\nC --> A\nA --> A", theme: .light))
        #expect(wellFormed(svg))
    }

    @Test func escapesLabels() throws {
        let svg = try #require(MermaidSource.svg(for: "graph TD\nA[a < b & c] --> B", theme: .dark))
        #expect(svg.contains("a &lt; b &amp; c"))
        #expect(wellFormed(svg))
    }

    @Test func flowchartSVGIsWellFormedForAllShapes() throws {
        let code = """
        ---
        title: Everything
        ---
        flowchart BT
        A[a] --> B(b) --> C([c]) --> D[[d]] --> E[(e)]
        F((f)) --> G>g] --> H{h} --> I{{i}} --> J[/j/]
        J --> K[\\k\\] --> L[/l\\]
        subgraph s [Sub]
        A --> M
        end
        """
        for theme in RichRenderSVG.Theme.allCases {
            let svg = try #require(MermaidSource.svg(for: code, theme: theme))
            #expect(wellFormed(svg))
            #expect(svg.contains("Everything"))
        }
    }

    @Test func sequenceDiagram() throws {
        let code = """
        sequenceDiagram
        autonumber
        participant A as Alice
        actor B
        A->>B: Hello & a < b
        B-->>A: Back
        A->>A: Think
        Note right of B: a note
        Note over A,B: shared
        alt ok
        A-)B: async
        else fail
        B--xA: nope
        end
        activate A
        A->>+B: go
        B-->>-A: done
        """
        let diagram = try #require(MermaidSequence.parse(lines: code.split(separator: "\n").dropFirst().map(String.init)))
        #expect(diagram.participants.map(\.label) == ["Alice", "B"])
        #expect(diagram.messageCount == 7)
        let svg = try #require(MermaidSource.svg(for: code, theme: .light))
        #expect(wellFormed(svg))
        #expect(svg.contains("Hello &amp; a &lt; b"))
    }

    @Test func pie() throws {
        let code = "pie showData\n title Pets\n \"Dogs\" : 386\n \"Cats\" : 85.5\n \"Rats\" : 15"
        let svg = try #require(MermaidSource.svg(for: code, theme: .dark))
        #expect(wellFormed(svg))
        #expect(svg.contains("Pets") && svg.contains("Dogs [386]"))
        let single = try #require(MermaidSource.svg(for: "pie\n\"Only\" : 1", theme: .light))
        #expect(wellFormed(single))
    }

    @Test func unsupportedReturnsNil() {
        for code in ["classDiagram\nA <|-- B", "gantt\ntitle x", "", "graph TD", "pie\ntitle x", "sequenceDiagram", "stateDiagram-v2\n[*] --> A"] {
            #expect(MermaidSource.svg(for: code, theme: .light) == nil, "\(code)")
        }
    }

    @Test func capsReturnNil() {
        let manyNodes = "graph TD\n" + (0..<151).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        #expect(MermaidSource.svg(for: manyNodes, theme: .light) == nil)
        let manyEdges = "graph TD\n" + (0..<401).map { _ in "A --> B" }.joined(separator: "\n")
        #expect(MermaidSource.svg(for: manyEdges, theme: .light) == nil)
        #expect(MermaidSource.svg(for: "graph TD\n" + String(repeating: "A --> B\n", count: 3000), theme: .light) == nil)
        let messages = "sequenceDiagram\n" + String(repeating: "A->>B: x\n", count: 401)
        #expect(MermaidSource.svg(for: messages, theme: .light) == nil)
    }

    @Test func deterministic() {
        let code = "graph TD\nA --> B\nA --> C\nB --> D\nC --> D\nD --> A"
        #expect(MermaidSource.svg(for: code, theme: .light) == MermaidSource.svg(for: code, theme: .light))
    }
}
