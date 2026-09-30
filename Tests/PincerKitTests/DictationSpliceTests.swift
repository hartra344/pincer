import Foundation
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

    // MARK: - #461: selection (UTF-16) and caret

    private func apply(_ draft: String, selection: NSRange?, _ partial: String) -> String {
        DictationSplice(draft: draft, selection: selection).applying(partial)
    }

    @Test func nilSelectionAppendsAtTheEnd() {
        #expect(apply("Hi", selection: nil, "there") == "Hi there")
        #expect(apply("Hi", selection: NSRange(location: NSNotFound, length: 0), "there") == "Hi there")
    }

    @Test func caretInTheMiddle() {
        #expect(apply("Hello world", selection: NSRange(location: 5, length: 0), "big") == "Hello big world")
        #expect(apply("Hello world", selection: NSRange(location: 0, length: 0), "Oh") == "Oh Hello world")
    }

    @Test func selectionIsReplaced() {
        #expect(apply("Hello big world", selection: NSRange(location: 6, length: 3), "small") == "Hello small world")
        #expect(apply("Hello world", selection: NSRange(location: 0, length: 11), "Bye") == "Bye")
        #expect(apply("Hello world", selection: NSRange(location: 6, length: 5), "there") == "Hello there")
    }

    @Test func selectionOfTheFirstWordKeepsTheRest() {
        let splice = DictationSplice(draft: "Hello world", selection: NSRange(location: 0, length: 5))
        #expect(splice.applying("Howdy") == "Howdy world")
        #expect(splice.applying("") == "Hello world", "an empty partial restores the draft")
        #expect(splice.caret(after: "") == 0)
    }

    @Test func emojiUsesUTF16OffsetsAndSnapsToCharacters() {
        let draft = "a😀b" // 😀 is two UTF-16 units
        #expect(apply(draft, selection: NSRange(location: 3, length: 0), "X") == "a😀 X b")
        // Caret in the middle of the surrogate pair snaps back to before the emoji.
        #expect(apply(draft, selection: NSRange(location: 2, length: 0), "X") == "a X 😀b")
        // A selection covering half the emoji grows to include all of it.
        #expect(apply(draft, selection: NSRange(location: 2, length: 1), "X") == "a X b")
        #expect(apply(draft, selection: NSRange(location: 1, length: 1), "X") == "a X b")
    }

    @Test func combiningMarksAreNotSplit() {
        let draft = "cafe\u{301} au lait" // é as e + combining acute
        let ns = draft as NSString
        #expect(ns.length == 13)
        // Caret between "e" and its accent snaps before the "e".
        #expect(apply(draft, selection: NSRange(location: 4, length: 0), "X") == "caf X e\u{301} au lait")
        #expect(apply(draft, selection: NSRange(location: 3, length: 2), "X") == "caf X au lait")
    }

    @Test func outOfRangeSelectionIsClamped() {
        #expect(apply("Hi", selection: NSRange(location: 99, length: 5), "there") == "Hi there")
        #expect(apply("Hi", selection: NSRange(location: -3, length: 1), "there") == "there Hi")
        #expect(apply("Hi", selection: NSRange(location: 1, length: 99), "there") == "H there")
        #expect(apply("", selection: NSRange(location: 4, length: 4), "hey") == "hey")
    }

    @Test func caretAfterUsesUTF16Offsets() {
        let splice = DictationSplice(draft: "Hello world", selection: NSRange(location: 5, length: 0))
        #expect(splice.applying("big") == "Hello big world")
        #expect(splice.caret(after: "big") == 9)
        #expect(splice.caret(after: "") == 5)
        #expect(splice.caret(after: "  big \n") == 9, "trimmed like applying")
    }

    @Test func caretAfterLeadingSpaceRules() {
        // No leading space when the text before ends in whitespace or is empty.
        #expect(DictationSplice(draft: "Hi ", selection: nil).caret(after: "there") == 8)
        #expect(DictationSplice(draft: "Hi\n", selection: nil).caret(after: "there") == 8)
        #expect(DictationSplice(draft: "", selection: nil).caret(after: "there") == 5)
        // Leading space added otherwise.
        #expect(DictationSplice(draft: "Hi", selection: nil).caret(after: "there") == 8)
    }

    @Test func caretIsBeforeTheTrailingSeparatorSpace() {
        let splice = DictationSplice(draft: "ab", selection: NSRange(location: 1, length: 0))
        let result = splice.applying("X") // "a X b"
        #expect(result == "a X b")
        #expect(splice.caret(after: "X") == 3)
        let punct = DictationSplice(draft: "Hello.", selection: NSRange(location: 5, length: 0))
        #expect(punct.applying("world") == "Hello world.")
        #expect(punct.caret(after: "world") == 11)
    }

    @Test func caretCountsEmojiAsTwoUnits() {
        let splice = DictationSplice(draft: "😀", selection: nil)
        #expect(splice.applying("hi") == "😀 hi")
        #expect(splice.caret(after: "hi") == 5)
        let dictated = DictationSplice(draft: "a", selection: nil)
        #expect(dictated.caret(after: "😀") == 4)
    }

    @Test func caretAfterReplacingASelectionStartsAtTheSelection() {
        let splice = DictationSplice(draft: "Hello big world", selection: NSRange(location: 6, length: 3))
        #expect(splice.caret(after: "small") == 11)
        #expect(splice.caret(after: "") == 6)
    }

    @Test func selectionSurvivesUntilWordsArrive() {
        let draft = "Hello big world"
        let splice = DictationSplice(draft: draft, selection: NSRange(location: 6, length: 3))
        #expect(splice.applying("") == draft)
        #expect(splice.applying("  \n") == draft)
        #expect(splice.caret(after: "") == 6)
        #expect(splice.caret(after: " ") == 6)
        #expect(splice.applying("small") == "Hello small world")
    }
}
