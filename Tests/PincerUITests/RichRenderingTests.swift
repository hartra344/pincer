import CoreGraphics
import Foundation
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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

    @Test func inlineMathBecomesSharedAttachments() {
        func attachments(_ s: NSAttributedString) -> [NSTextAttachment] {
            var found: [NSTextAttachment] = []
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { found.append(attachment) }
            }
            return found
        }
        let font = TranscriptStyle().body
        let text = TranscriptText.inline("Area is $\\pi r^2$, **not** $x_i$.", font: font, color: TranscriptColors.label)
        #expect(text.string == "Area is \u{FFFC}, not \u{FFFC}.")
        let first = attachments(text)
        #expect(first.count == 2)
        #expect((first.first?.bounds.minY ?? 0) < 0)
        // The same formula reuses its attachment, so a streaming prefix compares equal.
        let again = TranscriptText.inline("Area is $\\pi r^2$", font: font, color: TranscriptColors.label)
        #expect(attachments(again).first === first.first)
        let prices = TranscriptText.inline("It costs $5 and $10.", font: font, color: TranscriptColors.label)
        #expect(prices.string == "It costs $5 and $10.")
        let unknown = TranscriptText.inline("Keep $\\nope x$ as is", font: font, color: TranscriptColors.label)
        #expect(unknown.string == "Keep $\\nope x$ as is")
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
