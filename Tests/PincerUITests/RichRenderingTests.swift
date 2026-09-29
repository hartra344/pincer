import CoreGraphics
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Rich rendering", .serialized)
struct RichRenderingTests {
    @Test func fenceLanguagesMapToKinds() {
        #expect(RichBlock.kind(language: "mermaid") == .mermaid)
        #expect(RichBlock.kind(language: "math") == .math)
        #expect(RichBlock.kind(language: "latex") == .math)
        #expect(RichBlock.kind(language: "swift") == nil)
    }

    @Test func renderedBlocksAreCachedPerSourceAndAppearance() throws {
        let code = "graph LR\n  A[Start] --> B[Done]"
        let first = try #require(RichBlock.render(language: "mermaid", code: code, dark: false))
        let again = try #require(RichBlock.render(language: "mermaid", code: code, dark: false))
        #expect(first.ref == again.ref)
        #expect(first.size.width > 0 && first.size.height > 0)
        #expect(first.ref.alt == "Mermaid diagram")
        let dark = try #require(RichBlock.render(language: "mermaid", code: code, dark: true))
        #expect(dark.ref != first.ref)
    }

    @Test func unsupportedSourceStaysCode() {
        #expect(RichBlock.render(language: "mermaid", code: "gantt\n  title Plan", dark: false) == nil)
        #expect(RichBlock.render(language: "swift", code: "let a = 1", dark: false) == nil)
    }

    @Test func renderedSVGRasterizes() async throws {
        let math = try #require(RichBlock.render(language: "math", code: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, dark: false))
        let data = try #require(math.ref.base64.flatMap { Data(base64Encoded: $0) })
        let image = await SVGRasterizer.rasterize(data)
        #expect(image != nil)
    }

    @Test func liveSplitKeepsDisplayMathWhole() {
        let filler = String(repeating: "Words keep streaming in. ", count: 60)
        let source = "\(filler)\n\n$$\na^2\n\nb^2\n$$\n\n\(filler)\n\nTail"
        let live = TranscriptText.liveMarkdown(source, tone: .primary, row: "rich-math", owner: nil).map(\.segment)
        let committed = TranscriptText.markdown(source, tone: .primary)
        #expect(StreamingRenderingTests.merged(StreamingRenderingTests.flatten(live))
            == StreamingRenderingTests.merged(StreamingRenderingTests.flatten(committed)))
        #expect(StreamingRenderingTests.flatten(committed).contains("C:math:a^2\n\nb^2"))
    }
}
