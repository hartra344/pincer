import Foundation
import Testing
@testable import PincerUI

@Suite("Sidebar row edits (#571)")
struct SidebarRowEditsTests {
    func place(_ pairs: [(String, String?)]) -> [SidebarModel.Placement] {
        pairs.map { SidebarModel.Placement(id: $0.0, parent: $0.1) }
    }

    let base: [(String, String?)] = [("section:a", nil), ("chat:1", "section:a"), ("chat:2", "section:a"),
                                             ("section:b", nil), ("chat:3", "section:b")]

    @Test func aRowShowingUpIsOneInsertion() throws {
        let new = self.place([("section:a", nil), ("chat:1", "section:a"), ("chat:cron", "section:a"), ("chat:2", "section:a"),
                              ("section:b", nil), ("chat:3", "section:b")])
        let edits = try #require(SidebarModel.rowEdits(old: self.place(self.base), new: new))
        #expect(edits == ["section:a": .init(removed: [], inserted: [1])])
    }

    @Test func aRowGoingAwayIsOneRemoval() throws {
        let new = self.place([("section:a", nil), ("chat:2", "section:a"), ("section:b", nil), ("chat:3", "section:b")])
        let edits = try #require(SidebarModel.rowEdits(old: self.place(self.base), new: new))
        #expect(edits == ["section:a": .init(removed: [0], inserted: [])])
    }

    @Test func aRowChangingParentRebuilds() {
        let new = self.place([("section:a", nil), ("chat:2", "section:a"), ("section:b", nil), ("chat:1", "section:b"), ("chat:3", "section:b")])
        #expect(SidebarModel.rowEdits(old: self.place(self.base), new: new) == nil)
    }

    @Test func reorderedRowsRebuild() {
        let new = self.place([("section:a", nil), ("chat:2", "section:a"), ("chat:1", "section:a"), ("section:b", nil), ("chat:3", "section:b")])
        #expect(SidebarModel.rowEdits(old: self.place(self.base), new: new) == nil)
    }

    @Test func reorderedGroupsRebuild() {
        let new = self.place([("section:b", nil), ("chat:3", "section:b"), ("section:a", nil), ("chat:1", "section:a"), ("chat:2", "section:a")])
        #expect(SidebarModel.rowEdits(old: self.place(self.base), new: new) == nil)
    }

    @Test func manyChangesRebuild() {
        let many = (0..<9).map { ("chat:n\($0)", Optional("section:b")) }
        #expect(SidebarModel.rowEdits(old: self.place(self.base), new: self.place(self.base + many)) == nil)
    }
}

extension SidebarRowEditsTests {
    @Test func aHiddenGroupShowingUpWithItsChatIsOneTopLevelInsertion() throws {
        let new = self.place(self.base + [("section:automations", nil), ("chat:cron", "section:automations")])
        let edits = try #require(SidebarModel.rowEdits(old: self.place(self.base), new: new))
        #expect(edits == ["": .init(removed: [], inserted: [2])])
        let back = try #require(SidebarModel.rowEdits(old: new, new: self.place(self.base)))
        #expect(back == ["": .init(removed: [2], inserted: [])])
    }

    @Test func aGroupThatSwapsForAnotherWithTheSameChatRebuilds() {
        let old = self.place(self.base + [("section:x", nil), ("chat:9", "section:x")])
        let new = self.place(self.base + [("section:y", nil), ("chat:9", "section:y")])
        #expect(SidebarModel.rowEdits(old: old, new: new) == nil)
    }

    @Test func aChatUnderAParentThatEmptiesWithoutGoingRebuilds() {
        let old = self.place(self.base)
        let new = self.place([("section:a", nil), ("section:b", nil), ("chat:3", "section:b")])
        // section:a stays but loses all its rows: rare, so it simply rebuilds.
        #expect(SidebarModel.rowEdits(old: old, new: new) == nil)
    }
}
