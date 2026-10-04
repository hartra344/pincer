import Foundation
@testable import PincerKit
import Testing

@Suite("Bounded cold rotor opening")
struct ColdRotorTextOpeningTests {
    @Test func actualOpeningPreservesParagraphsAndEmptySeparators() {
        let value = ColdRotorTextOpening.capture(blocks: [.text("First"), .text("Second")])
        #expect(value.text == "First\n\nSecond" && value.inspectedBytes == 13 && value.visitedBlocks == 2)
        #expect(ColdRotorTextOpening.capture(blocks: [.text(""), .text("")]).text == "\n\n")
    }
    @Test func sharedByteAndTagLimitsAreReal() {
        let value = ColdRotorTextOpening.capture(blocks: [.text(String(repeating: "a", count: 1000)), .text("Later")])
        #expect(value.inspectedBytes == 400 && value.text.utf8.count == 400 && value.visitedBlocks == 1)
        let tags = ColdRotorTextOpening.capture(blocks: Array(repeating: .text(""), count: 100))
        #expect(tags.visitedBlocks == 64 && tags.inspectedBytes == 126)
        #expect(ColdRotorTextOpening.author(String(repeating: "a", count: 1000)).inspectedBytes == 128)
    }
    @Test func scalarCutsPreserveValidTextAndLiteralReplacement() {
        for scalar in ["é", "界", "😀"] {
            let prefix = String(repeating: "a", count: 399)
            let value = ColdRotorTextOpening.capture(text: prefix + scalar)
            #expect(value.text == prefix && value.inspectedBytes == 400)
        }
        #expect(ColdRotorTextOpening.capture(text: "Literal � survives").text == "Literal � survives")
        let giant = ColdRotorTextOpening.capture(text: "a" + String(repeating: "\u{301}", count: 100_000))
        #expect(giant.inspectedBytes == 400 && giant.text.utf8.count <= 400 && !giant.text.contains("�"))
    }
    @Test func foreignOpeningNeverMaterializesOnCapture() async throws {
        let value = await Task.detached { NSString(string: String(repeating: "\u{2003}", count: 20_000)) as String }.value
        try #require(!value.isContiguousUTF8)
        #expect(ColdRotorTextOpening.capture(text: value).text.isEmpty)
        #expect(ColdRotorTextOpening.capture(text: value).inspectedBytes == 0)
        #expect(ColdRotorTextOpening.author(value).text.isEmpty)
    }
}
