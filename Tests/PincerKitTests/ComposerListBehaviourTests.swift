import Foundation
import Testing
@testable import PincerKit

/// #1072: Tab / Shift-Tab renumber nested list items and Enter on an empty nested item outdents it.
@Suite("Composer list behaviour")
struct ComposerListBehaviourTests {
    typealias F = ComposerFormattingTests

    @Test func tabRestartsOrderedSublist() {
        #expect(F.indent("1. a\n2. b\n3. c|", outdent: false) == "1. a\n2. b\n   1. c|")
        #expect(F.indent("1) a\n2) b|", outdent: false) == "1) a\n   1) b|")
    }

    @Test func tabAdoptsPreviousSiblingMarker() {
        #expect(F.indent("1. a\n   1. b\n2. c|", outdent: false) == "1. a\n   1. b\n   2. c|")
        #expect(F.indent("- a\n  * b\n- c|", outdent: false) == "- a\n  * b\n  * c|")
    }

    @Test func tabSkipsDeeperLinesWhenFindingSibling() {
        #expect(F.indent("1. a\n   1. b\n      1. x\n2. c|", outdent: false) == "1. a\n   1. b\n      1. x\n   2. c|")
    }

    @Test func tabKeepsBulletCharWithoutSibling() {
        #expect(F.indent("* a\n* b|", outdent: false) == "* a\n  * b|")
    }

    @Test func shiftTabRenumbersAgainstParentLevel() {
        #expect(F.indent("1. a\n   1. b\n   2. c|", outdent: true) == "1. a\n   1. b\n2. c|")
        #expect(F.indent("1. a\n2. b\n   1. c|", outdent: true) == "1. a\n2. b\n3. c|")
    }

    @Test func shiftTabWithoutSiblingResetsOrderedToOne() {
        #expect(F.indent("   3. c|", outdent: true) == "1. c|")
        #expect(F.indent("  * a|", outdent: true) == "* a|")
    }

    @Test func multiLineTabSeesEarlierRenumbering() {
        let (text, sel) = F.parse("1. a\n[2. b\n3. c]")
        let edit = ComposerFormatting.indent(in: text as NSString, selection: sel, outdent: false)
        let r = F.apply(try! #require(edit), to: text)
        #expect(r.text == "1. a\n   1. b\n   2. c")
    }

    @Test func enterOnEmptyNestedItemOutdents() {
        #expect(F.newline("- a\n  - b\n  - |") == "- a\n  - b\n- |")
        #expect(F.newline("1. a\n   1. b\n   2. |") == "1. a\n   1. b\n2. |")
        #expect(F.newline("- a\n   1. b\n   2. |") == "- a\n   1. b\n- |")
        #expect(F.newline("- a\n  - [ ] |") == "- a\n- [ ] |")
    }

    @Test func enterOnEmptyTopLevelItemExits() {
        #expect(F.newline("- a\n- |") == "- a\n|")
        #expect(F.newline("1. a\n2. |") == "1. a\n|")
    }

    @Test func enterDoesNotRenumberFollowingLines() {
        #expect(F.newline("1. a\n   1. |\n2. c") == "1. a\n2. |\n2. c")
    }

    /// The reported sequence: Enter, Tab, type, Enter, Enter.
    @Test func reportedScenarioEndToEnd() {
        var state = "1. a|"
        state = F.newline(state)!
        #expect(state == "1. a\n2. |")
        state = F.indent(state, outdent: false)!
        #expect(state == "1. a\n   1. |")
        state = state.replacingOccurrences(of: "|", with: "b|")
        state = F.newline(state)!
        #expect(state == "1. a\n   1. b\n   2. |")
        state = F.newline(state)!
        #expect(state == "1. a\n   1. b\n2. |")
    }

    @Test func reportedBulletScenario() {
        var state = "- a|"
        state = F.newline(state)!
        state = F.indent(state, outdent: false)!
        #expect(state == "- a\n  - |")
        state = state.replacingOccurrences(of: "|", with: "b|")
        state = F.newline(state)!
        state = F.newline(state)!
        #expect(state == "- a\n  - b\n- |")
    }

    @Test func codeFenceAndPlainLinesUnchanged() {
        #expect(F.newline("```\n1. a|\n```") == nil)
        #expect(F.indent("plain|", outdent: false) == nil)
    }
}
