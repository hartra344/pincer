import Foundation
import Testing
@testable import PincerKit

/// The header chip shows whenever the chat has more than one branch (#449).
@Suite("Branch header chip")
struct BranchHeaderChipTests {
    let branches = [
        SessionBranch(leafEntryId: "a", headline: "one", messageCount: 2, active: false),
        SessionBranch(leafEntryId: "b", headline: "two", messageCount: 4, active: false),
        SessionBranch(leafEntryId: "c", headline: "three", messageCount: 3, active: true),
    ]

    @Test func labelNamesTheActiveBranchPosition() throws {
        let chip = try #require(BranchHeaderChip(branches: self.branches, hasAccess: true, isRunning: false))
        #expect(chip.label == "Branch 3 of 3")
        #expect(chip.entries.map(\.leafEntryId) == ["a", "b", "c"])
        #expect(chip.entries.map(\.isActive) == [false, false, true])
        #expect(chip.entries[1].title == BranchMenuEntry.title(for: self.branches[1]))
        #expect(chip.entries[1].title.hasSuffix("4 messages"))
        #expect(chip.canSwitch && chip.disabledReason == nil)
    }

    @Test func showsOnlyWithMoreThanOneBranch() {
        #expect(BranchHeaderChip(branches: Array(self.branches.prefix(1)), hasAccess: true, isRunning: false) == nil)
        #expect(BranchHeaderChip(branches: [], hasAccess: true, isRunning: false) == nil)
        #expect(BranchHeaderChip(branches: Array(self.branches.prefix(2)), hasAccess: true, isRunning: false) != nil)
    }

    @Test func explainsWhySwitchingIsOff() throws {
        let noAccess = try #require(BranchHeaderChip(branches: self.branches, hasAccess: false, isRunning: false))
        #expect(!noAccess.canSwitch && noAccess.disabledReason?.contains("Full Management") == true)
        let running = try #require(BranchHeaderChip(branches: self.branches, hasAccess: true, isRunning: true))
        #expect(!running.canSwitch && running.disabledReason == "Wait for the reply to finish.")
    }
}
