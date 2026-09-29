import Foundation
import Testing
@testable import PincerKit

@Suite("Read Aloud text")
struct SpeechTextTests {
    private func plain(_ s: String) -> String { SpeechText.plain(fromMarkdown: s) }

    @Test(arguments: [
        ("Hello **bold** and *italic* and ~~gone~~ and _under_.", "Hello bold and italic and gone and under."),
        ("Use `swift build` now", "Use swift build now"),
        ("See [the docs](https://example.com/a) please", "See the docs please"),
        ("Visit https://example.com/path?x=1 today", "Visit today"),
        ("Look ![a chart](https://x.test/c.png) here", "Look here"),
        ("# Title\n\nBody text.", "Title.\n\nBody text."),
        ("> quoted line\n> more", "quoted line more"),
        ("Hi <b>there</b> friend", "Hi there friend"),
        ("  lots   of\t space  ", "lots of space"),
    ])
    func inlineStripping(input: String, expected: String) {
        #expect(plain(input) == expected)
    }

    @Test func listMarkersAreRemoved() {
        let spoken = plain("Steps:\n- first\n- second\n1. third\n2) fourth")
        #expect(!spoken.contains("- ") && !spoken.contains("1."))
        for word in ["first", "second", "third", "fourth"] { #expect(spoken.contains(word)) }
    }

    @Test func fencedCodeIsSkipped() {
        #expect(plain("Before\n\n```swift\nlet x = 1\nprint(x)\n```\n\nAfter") == "Before\n\nAfter")
        #expect(plain("Before\n\n~~~\ncode\n~~~\n\nAfter") == "Before\n\nAfter")
        let spoken = plain("A\n```mermaid\ngraph TD; a-->b\n```\nB\n```math\nx^2\n```\nC")
        #expect(!spoken.contains("graph") && !spoken.contains("x^2"))
        #expect(spoken.contains("A") && spoken.contains("B") && spoken.contains("C"))
        #expect(!plain("Text\n```\nunterminated code\nmore").contains("unterminated"))
        #expect(plain("```\nonly code\n```") == "")
    }

    @Test func displayMathIsSkipped() {
        let spoken = plain("Before\n\n$$\nE = mc^2\n$$\n\nAfter")
        #expect(!spoken.contains("mc") && spoken.contains("Before") && spoken.contains("After"))
    }

    @Test func tablesReadAsCells() {
        let spoken = plain("| Name | Age |\n|------|-----|\n| Ann | 30 |")
        #expect(!spoken.contains("|") && !spoken.contains("---"))
        #expect(spoken.contains("Name") && spoken.contains("Ann") && spoken.contains("30"))
    }

    @Test func mediaDirectivesAreDropped() {
        let spoken = plain("Here you go\nMEDIA:/tmp/photo.png\nEnjoy")
        #expect(!spoken.contains("MEDIA") && !spoken.contains("photo.png"))
        #expect(spoken.contains("Here you go") && spoken.contains("Enjoy"))
    }

    @Test func paragraphsAreJoinedWithBlankLine() {
        #expect(plain("One\n\n\n\nTwo\nthree") == "One\n\nTwo three")
    }

    @Test func emptyAfterStripping() {
        #expect(plain("") == "")
        #expect(plain("   \n\n ") == "")
        #expect(plain("![img](https://x.test/a.png)") == "")
    }

    // MARK: truncation

    @Test func shortTextIsUntouched() {
        #expect(SpeechText.truncated("Short.", limit: 100) == "Short.")
        #expect(SpeechText.truncated(String(repeating: "a", count: 4000)).count == 4000)
    }

    @Test func truncatesAtSentenceBoundary() {
        let text = "First sentence here. Second sentence here. Third sentence that keeps going and going"
        let cut = SpeechText.truncated(text, limit: 50)
        #expect(cut == "First sentence here. Second sentence here.")
    }

    @Test func truncatesAtWordBoundaryWithoutSentences() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        let cut = SpeechText.truncated(text, limit: 30)
        #expect(cut.count <= 30 && !cut.hasSuffix(" "))
        #expect(text.hasPrefix(cut))
        #expect(cut.split(separator: " ").allSatisfy { text.split(separator: " ").contains($0) }, "no half words")
    }

    @Test func truncatesHardWithoutBoundaries() {
        let cut = SpeechText.truncated(String(repeating: "a", count: 200), limit: 50)
        #expect(cut.count == 50)
    }

    @Test func defaultLimitIsFourThousand() {
        let long = String(repeating: "Sentence number one. ", count: 400)
        let cut = SpeechText.truncated(long)
        #expect(cut.count <= 4000 && cut.hasSuffix("."))
    }

    // MARK: speakableText

    @Test func onlyAssistantTextBlocksAreSpoken() {
        let item = ChatItem(id: "a", role: .assistant, blocks: [
            .thinking("secret thoughts"),
            .toolCall(id: "t1", name: "exec", arguments: "{\"cmd\":\"ls\"}"),
            .text("Here is **the answer**."),
        ])
        #expect(SpeechText.speakableText(for: item) == "Here is the answer.")
    }

    @Test func nonAssistantOrEmptyIsNotSpeakable() {
        #expect(SpeechText.speakableText(for: ChatItem(id: "u", role: .user, blocks: [.text("hello")])) == nil)
        #expect(SpeechText.speakableText(for: ChatItem(id: "t", role: .toolResult, blocks: [.text("output")])) == nil)
        #expect(SpeechText.speakableText(for: ChatItem(id: "a", role: .assistant, blocks: [.thinking("hm")])) == nil)
        #expect(SpeechText.speakableText(for: ChatItem(id: "a", role: .assistant, blocks: [.text("```\ncode\n```")])) == nil)
        var pending = ChatItem(id: "p", role: .assistant, blocks: [.text("streaming")])
        pending.isPending = true
        #expect(SpeechText.speakableText(for: pending) == nil)
        var failed = ChatItem(id: "e", role: .assistant, blocks: [.text("oops")])
        failed.isError = true
        #expect(SpeechText.speakableText(for: failed) == nil)
    }
}
