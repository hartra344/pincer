import Foundation
import Testing
@testable import PincerKit

/// The header chip shows only with branches, and only while the inline switcher is off screen (#449).
@Suite("Branch header chip")
struct BranchHeaderChipTests {
    let branches = [
        SessionBranch(leafEntryId: "a", headline: "one", messageCount: 2, active: false),
        SessionBranch(leafEntryId: "b", headline: "two", messageCount: 4, active: false),
        SessionBranch(leafEntryId: "c", headline: "three", messageCount: 3, active: true),
    ]

    @Test func labelNamesTheActiveBranchPosition() throws {
        let chip = try #require(BranchHeaderChip(branches: self.branches, anchorVisible: false, canSwitch: true))
        #expect(chip.label == "Branch 3 of 3")
        #expect(chip.entries.map(\.leafEntryId) == ["a", "b", "c"])
        #expect(chip.entries.map(\.isActive) == [false, false, true])
        #expect(chip.entries[1].title == BranchMenuEntry.title(for: self.branches[1]))
        #expect(chip.entries[1].title.hasSuffix("4 messages"))
        #expect(chip.canSwitch)
    }

    @Test func hidesWhenAnchorIsVisibleOrThereIsOneBranch() {
        #expect(BranchHeaderChip(branches: self.branches, anchorVisible: true, canSwitch: true) == nil)
        #expect(BranchHeaderChip(branches: Array(self.branches.prefix(1)), anchorVisible: false, canSwitch: true) == nil)
        #expect(BranchHeaderChip(branches: [], anchorVisible: false, canSwitch: true) == nil)
    }

    @Test func switchingFlagPassesThrough() throws {
        let chip = try #require(BranchHeaderChip(branches: self.branches, anchorVisible: false, canSwitch: false))
        #expect(!chip.canSwitch)
    }
}
