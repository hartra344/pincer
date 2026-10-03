import Testing
@testable import PincerKit

@Suite("Grouped message part selection")
struct MessagePartKeyboardSelectionTests {
    @Test func arrowsClampAtBothEdgesWithoutWrapping() {
        var selection = TranscriptMessagePartSelection()
        let ids = ["first", "second", "third"]
        #expect(selection.reconcile(rowID: "row", messageIDs: ids) == "first")
        #expect(selection.move(forward: false, rowID: "row", messageIDs: ids) == "first")
        #expect(selection.move(forward: true, rowID: "row", messageIDs: ids) == "second")
        #expect(selection.move(forward: true, rowID: "row", messageIDs: ids) == "third")
        #expect(selection.move(forward: true, rowID: "row", messageIDs: ids) == "third")
        #expect(selection.move(forward: false, rowID: "row", messageIDs: ids) == "second")
    }

    @Test func editsAndReorderingPreserveIdentityButDeletionFallsBack() {
        var selection = TranscriptMessagePartSelection()
        selection.move(forward: true, rowID: "row", messageIDs: ["first", "second", "third"])
        #expect(selection.reconcile(rowID: "row", messageIDs: ["third", "second", "first"]) == "second")
        #expect(selection.reconcile(rowID: "row", messageIDs: ["third", "first"]) == "third")
        #expect(selection.rowID == "row")
        #expect(selection.messageID == "third")
    }

    @Test func rowTransitionsEmptyRowsAndContextResetDoNotKeepOldTargets() {
        var selection = TranscriptMessagePartSelection()
        selection.move(forward: true, rowID: "row", messageIDs: ["first", "second"])
        #expect(selection.reconcile(rowID: "other", messageIDs: ["other-first", "other-second"]) == "other-first")
        #expect(selection.reconcile(rowID: "row", messageIDs: ["first", "second"]) == "first")
        #expect(selection.reconcile(rowID: "row", messageIDs: []) == nil)
        #expect(selection.move(forward: true, rowID: "row", messageIDs: []) == nil)
        selection.reconcile(rowID: nil, messageIDs: [])
        #expect(selection.rowID == nil)
        #expect(selection.messageID == nil)
        #expect(selection.reconcile(rowID: "row", messageIDs: ["new-first", "second"]) == "new-first")
    }

    @Test func aSinglePartNeverChangesItsIdentity() {
        var selection = TranscriptMessagePartSelection()
        #expect(selection.move(forward: true, rowID: "single", messageIDs: ["only"]) == "only")
        #expect(selection.move(forward: false, rowID: "single", messageIDs: ["only"]) == "only")
    }
}
