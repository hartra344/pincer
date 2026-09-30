import Testing
@testable import PincerKit

@Suite("Dictation splice")
struct DictationSpliceTests {
    private func apply(_ draft: String, at offset: Int?, _ partial: String) -> String {
        DictationSplice(draft: draft, insertionOffset: offset).applying(partial)
    }

    @Test func emptyDraft() {
        #expect(apply("", at: nil, "hello there") == "hello there")
        #expect(apply("", at: 0, "hello there") == "hello there")
    }

    @Test func appendsAtEndWithSpace() {
        #expect(apply("Hi", at: nil, "there") == "Hi there")
        #expect(apply("Hi ", at: nil, "there") == "Hi there")
        #expect(apply("Hi\n", at: nil, "there") == "Hi\nthere")
    }

    @Test func insertsInTheMiddleWithSpacesBothSides() {
        #expect(apply("Hello world", at: 5, "big") == "Hello big world")
        #expect(apply("Hello  world", at: 6, "big") == "Hello big world")
        #expect(apply("ab", at: 1, "X") == "a X b")
    }

    @Test func noSpaceBeforePunctuationAfter() {
        #expect(apply("Hello.", at: 5, "world") == "Hello world.")
        #expect(apply("Hi, bye", at: 2, "there") == "Hi there, bye")
    }

    @Test func atStartSpacesBeforeExistingText() {
        #expect(apply("world", at: 0, "Hello") == "Hello world")
        #expect(apply(" world", at: 0, "Hello") == "Hello world")
    }

    @Test func offsetIsClamped() {
        #expect(apply("Hi", at: 99, "there") == "Hi there")
        #expect(apply("Hi", at: -5, "there") == "there Hi")
    }

    @Test func emptyOrBlankPartialRestoresDraft() {
        #expect(apply("Hello world", at: 5, "") == "Hello world")
        #expect(apply("Hello world", at: 5, "  \n ") == "Hello world")
    }

    @Test func partialIsTrimmed() {
        #expect(apply("A", at: nil, "  b  ") == "A b")
    }

    @Test func replacingPartialsNeverGrowsTheSurroundings() {
        let splice = DictationSplice(draft: "Hello world", insertionOffset: 5)
        #expect(splice.applying("one") == "Hello one world")
        #expect(splice.applying("one two three") == "Hello one two three world")
        #expect(splice.applying("") == "Hello world")
    }

    @Test func countsCharactersNotUTF16() {
        #expect(apply("👍🏽 ok", at: 1, "yes") == "👍🏽 yes ok")
    }

    @Test func capturesBeforeAndAfter() {
        let splice = DictationSplice(draft: "abc", insertionOffset: 1)
        #expect(splice.before == "a" && splice.after == "bc")
    }
}
