import Foundation
import Testing
@testable import PincerKit

@Suite("Sidebar unread avatar (#317)")
struct SidebarUnreadAvatarTests {
    let moki = AgentSummary(id: "main", name: "Moki", emoji: "🦞")

    func unread(_ isUnread: Bool = true, subagent: Bool = false, companions: Bool = true) -> SidebarWorkingIndicator? {
        SidebarWorkingIndicator.resolveUnread(isUnread: isUnread, isSubagent: subagent, agent: self.moki,
                                              companionsEnabled: companions)
    }

    func working(helpers: Int = 0, run: Bool = false, unread: Bool, companions: Bool = true) -> SidebarWorkingIndicator? {
        SidebarWorkingIndicator.resolve(hasActiveRun: run, runningSubagents: helpers, showSubagentRuns: false,
                                        agent: self.moki, companionsEnabled: companions, isUnread: unread)
    }

    @Test func idleUnreadWithAvatarsShowsUnreadMode() throws {
        let indicator = try #require(self.unread())
        #expect(indicator.mode == .unread)
        #expect(indicator.source == .companion)
        #expect(indicator.showsUnreadMark)
        #expect(indicator.badge == nil)
        #expect(!indicator.isWorking)
        #expect(indicator.agentId == "main")
    }

    @Test func fallsBackToDotWhenAvatarsOffSubagentOrRead() {
        #expect(self.unread(companions: false) == nil)
        #expect(self.unread(subagent: true) == nil)
        #expect(self.unread(false) == nil)
    }

    @Test func workingUnreadShowsMarkWithoutHelpers() throws {
        let indicator = try #require(self.working(run: true, unread: true))
        #expect(indicator.mode == .working && indicator.isWorking)
        #expect(indicator.isUnread && indicator.showsUnreadMark)
        #expect(indicator.label == "Moki is working")
    }

    @Test func helperCountBadgeWinsOverUnreadMark() throws {
        let indicator = try #require(self.working(helpers: 2, unread: true))
        #expect(indicator.badge == "2")
        #expect(!indicator.showsUnreadMark)
        #expect(indicator.label == "Moki: 2 helper runs working")
    }

    @Test func workingReadHasNoMarkAndLabelsUnchanged() throws {
        let own = try #require(self.working(run: true, unread: false, companions: false))
        #expect(own.mode == .working && !own.isUnread && !own.showsUnreadMark)
        #expect(own.label == "Moki is working" && own.source == .emoji("🦞"))
        #expect(self.working(unread: true) == nil)
    }

    @Test func workingWithUnreadWorksWithAvatarsOff() throws {
        let indicator = try #require(self.working(run: true, unread: true, companions: false))
        #expect(indicator.source == .emoji("🦞") && indicator.showsUnreadMark)
    }
}
