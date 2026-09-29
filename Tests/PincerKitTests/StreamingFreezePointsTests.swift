import Foundation
import Testing
@testable import PincerKit

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Streaming freeze points")
struct StreamingFreezePointsTests {
    static let pieces: [String] = [
        "Plain paragraph with **bold** and `code`.",
        "Two lines\nin one paragraph.",
        "# Heading one",
        "## Heading two\nfollowed by text",
        "- bullet a\n- bullet b\n- bullet c",
        "1. first\n2. second\n3. third",
        "1. one\n\n2. two after blank\n\n3. three",
        "- loose a\n\n- loose b",
        "- item\n  continued indented\n- next",
        "> quoted line\n> more quote",
        "> quote\n\n> another quote",
        "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |",
        "| h |\n|---|\n| x |\n\n| y |",
        "```swift\nlet a = 1\n\nlet b = 2\n```",
        "```\nno language\n\n\n\nblank lines inside\n```",
        "~~~\ntilde fence\n\nstill inside\n~~~",
        "```\nunterminated fence\n\nwith blank",
        "    indented code line\n\n    second indented",
        "---",
        "Text right before a list:\n- a\n- b",
        "  \t  ",
        "Ünïcödé 😀 text with émoji and 日本語",
        "* star\n* bullets",
        "+ plus\n+ bullets\n\n1) paren\n2) numbers",
        "- [ ] todo\n- [x] done",
    ]

    static func generate(seed: UInt64, count: Int) -> String {
        var rng = SplitMix64(state: seed)
        var out = ""
        for _ in 0..<count {
            out += pieces.randomElement(using: &rng)!
            out += ["\n\n", "\n\n", "\n\n\n", "\n"].randomElement(using: &rng)!
        }
        return out
    }

    static func chunks(_ text: String, _ cuts: [String.Index]) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        for cut in cuts { result.append(String(text[start..<cut])); start = cut }
        result.append(String(text[start...]))
        return result
    }

    static func joinedParse(_ text: String, minimumChunk: Int) -> [MarkdownBlock] {
        chunks(text, MarkdownBlock.streamingFreezePoints(text, minimumChunk: minimumChunk))
            .flatMap { MarkdownBlock.parse($0) }
    }

    static func offsets(_ text: String, _ cuts: [String.Index]) -> [Int] {
        cuts.map { text.utf8.distance(from: text.utf8.startIndex, to: $0) }
    }

    @Test func emptyAndTinyTextsHaveNoCuts() {
        #expect(MarkdownBlock.streamingFreezePoints("").isEmpty)
        #expect(MarkdownBlock.streamingFreezePoints("hi").isEmpty)
        #expect(MarkdownBlock.streamingFreezePoints("a\n\nb").isEmpty)
    }

    @Test func defaultMinimumChunkKeepsShortTextInOneChunk() {
        let text = Self.generate(seed: 1, count: 3)
        #expect(text.utf16.count < 1024)
        #expect(MarkdownBlock.streamingFreezePoints(text).isEmpty)
    }

    @Test func cutsAreAscendingAtLineStartsAfterBlankLines() {
        for seed in UInt64(1)...20 {
            let text = Self.generate(seed: seed, count: 30)
            let cuts = MarkdownBlock.streamingFreezePoints(text, minimumChunk: 40)
            var last = text.startIndex
            for cut in cuts {
                #expect(cut > last)
                #expect(cut < text.endIndex)
                let before = text[..<cut]
                #expect(before.hasSuffix("\n\n") || before.hasSuffix("\n \n") || before.hasSuffix("\n\t\n")
                    || before.split(separator: "\n", omittingEmptySubsequences: false).dropLast().last?
                        .trimmingCharacters(in: .whitespaces).isEmpty == true)
                last = cut
            }
        }
    }

    @Test func handCasesKeepBlocksIdentical() {
        let cases = [
            "1. one\n2. two\n\n3. three\n4. four",
            "- a\n\n- b\n\n- c",
            "1. one\n\n2. two\n\n3. three\n\ntext",
            "> a\n\n> b\n\n> c",
            "| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |",
            "```\na\n\nb\n```\n\nafter",
            "```\na\n\nb",
            "para\n\n    code\n\n    code2\n\npara",
            "- a\n  cont\n\n  more indented\n- b",
            "# h\n\n# h2\n\n# h3",
            "a\n\n\n\nb\n\n\nc",
            "text\n\n- a\n- b\n\n1. x\n2. y\n\nend",
            "```swift\nx\n```\n\n```swift\ny\n```\n",
            "trailing blank\n\n",
            "\n\nleading blanks",
        ]
        for text in cases {
            for minimum in [0, 1, 3, 10] {
                #expect(Self.joinedParse(text, minimumChunk: minimum) == MarkdownBlock.parse(text),
                        "text: \(text.debugDescription) min: \(minimum)")
            }
        }
    }

    @Test func randomTextAndAllPrefixesKeepBlocksIdentical() {
        for seed in UInt64(100)...115 {
            let text = Self.generate(seed: seed, count: 25)
            let indices = Array(text.indices)
            for minimum in [1, 30, 200] {
                for offset in stride(from: 0, to: indices.count, by: 5) {
                    let prefix = String(text[..<indices[offset]])
                    #expect(Self.joinedParse(prefix, minimumChunk: minimum) == MarkdownBlock.parse(prefix),
                            "seed \(seed) min \(minimum) prefix \(offset)")
                }
                #expect(Self.joinedParse(text, minimumChunk: minimum) == MarkdownBlock.parse(text))
            }
        }
    }

    @Test func cutPointsAreStableUnderAppend() {
        for seed in UInt64(200)...212 {
            let text = Self.generate(seed: seed, count: 25)
            for minimum in [1, 30, 200] {
                let full = Self.offsets(text, MarkdownBlock.streamingFreezePoints(text, minimumChunk: minimum))
                var previous: [Int] = []
                var cursor = text.startIndex
                while cursor < text.endIndex {
                    cursor = text.index(cursor, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                    let prefix = String(text[..<cursor])
                    let offsets = Self.offsets(prefix, MarkdownBlock.streamingFreezePoints(prefix, minimumChunk: minimum))
                    // Earlier cuts never move or disappear, and only ever agree with the full text's.
                    #expect(Array(offsets.prefix(previous.count)) == previous, "seed \(seed) min \(minimum)")
                    #expect(offsets == Array(full.prefix(offsets.count)), "seed \(seed) min \(minimum)")
                    previous = offsets
                }
                #expect(previous == full)
            }
        }
    }

    @Test func greedyChunksReachMinimumSize() {
        let text = Self.generate(seed: 7, count: 60)
        let minimum = 300
        let parts = Self.chunks(text, MarkdownBlock.streamingFreezePoints(text, minimumChunk: minimum))
        #expect(parts.count > 2)
        for part in parts.dropLast() { #expect(part.utf16.count >= minimum) }
    }

    @Test func noCutInsideFence() {
        let text = "intro\n\n```\n" + String(repeating: "line\n\n", count: 200) + "```\n\nafter para\n\nend"
        let cuts = MarkdownBlock.streamingFreezePoints(text, minimumChunk: 1)
        let fenceStart = text.range(of: "```")!.lowerBound
        let fenceEnd = text.range(of: "after para")!.lowerBound
        for cut in cuts { #expect(cut <= fenceStart || cut >= fenceEnd) }
        #expect(Self.joinedParse(text, minimumChunk: 1) == MarkdownBlock.parse(text))
    }

    @Test func largeTextIsFast() {
        let text = String(repeating: Self.generate(seed: 3, count: 10), count: 40)
        let start = Date()
        let cuts = MarkdownBlock.streamingFreezePoints(text)
        #expect(!cuts.isEmpty)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
