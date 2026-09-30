import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #342: highlighting only adds foreground colors, so the text Find marks against is unchanged.
@Suite("Tool highlights")
struct ToolHighlightTests {
    private func presentation(_ name: String, args: String, result: String) -> ToolCallPresentation {
        ToolCallPresentation.make(ToolActivity(id: "t", name: name, arguments: args, result: result, isError: false, isRunning: false))
    }

    @Test func readOfSwiftFileHighlightsWithoutChangingText() throws {
        let p = self.presentation("read", args: #"{"path":"A.swift"}"#, result: DemoGateway.toolCardsSwiftText)
        let text = try #require(p.output?.text)
        let highlights = ToolHighlights.make(p)
        #expect(!highlights.output.isEmpty)
        let plain = NSAttributedString(string: text)
        let colored = TranscriptSyntaxColors.apply(highlights.output, to: plain)
        #expect(colored.string == text, "Find marks index the same characters")
        var colors = 0
        colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { value, _, _ in
            if value != nil { colors += 1 }
        }
        #expect(colors > 0)
    }

    @Test func jsonOutputAndNestedArgumentsAreHighlighted() throws {
        let p = self.presentation("github__search_issues", args: #"{"query":"x","filter":{"state":"open","n":3}}"#,
                                  result: DemoGateway.toolCardsIssuesJSON)
        let highlights = ToolHighlights.make(p)
        #expect(highlights.output.contains { $0.kind == .key } && highlights.output.contains { $0.kind == .string })
        #expect(highlights.arguments.contains { $0.kind == .key || $0.kind == .string })
        let args = try #require(p.argumentsText)
        for token in highlights.arguments { #expect(NSMaxRange(token.range) <= (args as NSString).length) }
    }

    @Test func plainOutputAndErrorsAreNotHighlighted() {
        #expect(ToolHighlights.make(self.presentation("exec", args: #"{"command":"ls"}"#, result: "a\nb")).output.isEmpty)
        let failed = ToolCallPresentation.make(ToolActivity(id: "t", name: "read", arguments: #"{"path":"A.swift"}"#,
                                                            result: "let x = 1", isError: true, isRunning: false))
        #expect(ToolHighlights.make(failed).output.isEmpty)
        #expect(ToolHighlights.make(self.presentation("read", args: #"{"path":"README.md"}"#, result: "# Title\nlet x")).output.isEmpty)
    }

    @Test func highlightingIsCheapOnAMaximumSizedOutput() {
        let big = String(repeating: "let value = \"text\" // comment 123\n", count: 20_000 / 36)
        let p = self.presentation("read", args: #"{"path":"A.swift"}"#, result: big)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = ToolHighlights.make(p) }
        #expect(elapsed < PerfBudget.limit(.milliseconds(200)), "\(elapsed)")
    }

    @Test func tokenColorsMeetContrast() {
        func luminance(_ rgb: Int) -> Double {
            func channel(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF) + 0.0722 * channel(rgb & 0xFF)
        }
        func ratio(_ a: Int, _ b: Int) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for kind in [ToolSyntax.TokenKind.key, .string, .number, .keyword, .comment] {
            let hex = TranscriptSyntaxColors.hex(kind)
            #expect(ratio(hex.light, 0xFFFFFF) >= 4.5, "\(kind) light")
            #expect(ratio(hex.dark, 0x1C1C1E) >= 4.5, "\(kind) dark")
        }
    }
}
