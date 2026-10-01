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

    @Test func twoSentencesPerChunkThroughout() {
        let text = "One. Two. Three. Four.\n\nFive. Six. Seven."
        #expect(SpeechChunker.chunks(text) == ["One. Two.", "Three. Four.", "Five. Six.", "Seven."])
    }

    @Test func paragraphsDontMakeBigChunks() {
        let paragraph = (1 ... 12).map { "Sentence \($0) is short." }.joined(separator: " ")
        let chunks = SpeechChunker.chunks(paragraph + "\n\n" + paragraph)
        #expect(chunks.count == 12)
        #expect(chunks.allSatisfy { $0.count < 60 })
    }

    @Test func capKeepsTwoLongSentencesApart() {
        let long = "This" + String(repeating: " word", count: 40) + "." // 205 chars
        #expect(SpeechChunker.chunks("\(long) \(long)") == [long, long])
    }

    @Test func longSingleSentenceIsSplit() {
        let sentence = (1 ... 400).map { "w\($0)" }.joined(separator: " ") + "."
        let chunks = SpeechChunker.chunks(sentence)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= SpeechChunker.limit && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
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
        #expect(chunks[1] == "Does it work? Sentence number 1 has a few words in it.")
        #expect(self.squashed(chunks.joined()) == self.squashed(text))
    }
}
