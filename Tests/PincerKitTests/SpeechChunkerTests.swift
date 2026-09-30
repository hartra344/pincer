import Foundation
import Testing
@testable import PincerKit

@Suite("Speech chunker")
struct SpeechChunkerTests {
    private func squashed(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    @Test func emptyAndWhitespaceGiveNoChunks() {
        #expect(SpeechChunker.chunks("").isEmpty)
        #expect(SpeechChunker.chunks("  \n\n \t ").isEmpty)
    }

    @Test func shortTextIsOneChunk() {
        #expect(SpeechChunker.chunks("Hello there.") == ["Hello there."])
    }

    @Test func firstChunkIsOneOrTwoSentences() {
        let text = "First one. Second one. Third one. Fourth one.\n\nNext paragraph here."
        let chunks = SpeechChunker.chunks(text)
        #expect(chunks.first == "First one. Second one.")
        #expect(chunks.dropFirst().first == "Third one. Fourth one.\n\nNext paragraph here.")
    }

    @Test func firstChunkStopsBeforeFirstLimit() {
        let long = "Then" + String(repeating: " word", count: 30) + "."
        let chunks = SpeechChunker.chunks("Short start. \(long) End.", firstLimit: 100)
        #expect(chunks.first == "Short start.")
    }

    @Test func paragraphsGroupUpToTheCap() {
        let para = String(repeating: "abc ", count: 40).trimmingCharacters(in: .whitespaces) + "." // 160 chars
        let text = (["Intro."] + Array(repeating: para, count: 6)).joined(separator: "\n\n")
        let chunks = SpeechChunker.chunks(text, limit: 400)
        #expect(chunks.first == "Intro.")
        #expect(chunks.dropFirst().allSatisfy { $0.count <= 400 })
        #expect(chunks.count == 4) // Intro, then 2 paragraphs per chunk
        #expect(chunks[1] == "\(para)\n\n\(para)")
    }

    @Test func oversizedParagraphSplitsAtSentences() {
        let sentence = "Xy" + String(repeating: " xy", count: 29) + "." // 90 chars
        let big = Array(repeating: sentence, count: 10).joined(separator: " ")
        let chunks = SpeechChunker.chunks("Hi.\n\n" + big, limit: 300)
        #expect(chunks.dropFirst().allSatisfy { $0.count <= 300 && $0.hasSuffix(".") })
        #expect(chunks.count == 5) // Hi, then 3+3+3+1 sentences
    }

    @Test func longSingleSentenceIsSplit() {
        let sentence = (1 ... 400).map { "w\($0)" }.joined(separator: " ") + "."
        let chunks = SpeechChunker.chunks(sentence, firstLimit: 200, limit: 700)
        #expect(chunks[0].count <= 200)
        #expect(chunks.allSatisfy { $0.count <= 700 })
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
    }

    @Test func textIsFullyCoveredInOrder() {
        let text = """
        Pincer reads long replies in pieces. The first piece is short! Does it work?

        \((1 ... 60).map { "Sentence number \($0) has a few words in it." }.joined(separator: " "))

        Tiny.
        Also tiny.

        \((1 ... 300).map { "z\($0)" }.joined(separator: " "))
        """
        let chunks = SpeechChunker.chunks(text)
        #expect(chunks.allSatisfy { $0.count <= SpeechChunker.limit && !$0.isEmpty })
        #expect(chunks[0] == "Pincer reads long replies in pieces. The first piece is short!")
        #expect(self.squashed(chunks.joined()) == self.squashed(text))
    }
}
