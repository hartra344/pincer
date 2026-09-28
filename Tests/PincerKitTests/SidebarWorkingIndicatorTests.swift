import Foundation
import Testing
@testable import PincerKit

@Suite("Sidebar working indicator")
struct SidebarWorkingIndicatorTests {
    let moki = AgentSummary(id: "main", name: "Moki", emoji: "🦞")

    func resolve(run: Bool = false, helpers: Int = 0, listed: Bool = false, agent: AgentSummary? = nil,
                 companions: Bool = false) -> SidebarWorkingIndicator?
    {
        SidebarWorkingIndicator.resolve(hasActiveRun: run, runningSubagents: helpers, showSubagentRuns: listed,
                                        agent: agent ?? self.moki, companionsEnabled: companions)
    }

    @Test func notWorkingIsNil() {
        #expect(self.resolve() == nil)
        #expect(self.resolve(listed: true) == nil)
        #expect(self.resolve(companions: true) == nil)
    }

    @Test func ownRun() throws {
        let indicator = try #require(self.resolve(run: true))
        #expect(indicator.agentId == "main" && indicator.agentName == "Moki")
        #expect(indicator.label == "Moki is working")
        #expect(indicator.source == .emoji("🦞"))
        #expect(indicator.helperRuns == 0 && indicator.badge == nil)
    }

    @Test func hiddenHelperRuns() throws {
        let one = try #require(self.resolve(helpers: 1))
        #expect(one.helperRuns == 1 && one.badge == "1" && one.label == "Moki: 1 helper run working")
        let three = try #require(self.resolve(helpers: 3))
        #expect(three.helperRuns == 3 && three.badge == "3" && three.label == "Moki: 3 helper runs working")
        #expect(self.resolve(helpers: 9)?.badge == "9")
    }

    /// Listed helper runs show their own rows, so the parent isn't working on their account.
    @Test func listedHelperRunsDontCount() {
        #expect(self.resolve(helpers: 2, listed: true) == nil)
        let own = self.resolve(run: true, helpers: 2, listed: true)
        #expect(own?.helperRuns == 0 && own?.label == "Moki is working")
    }

    @Test func ownRunWinsOverHelpers() throws {
        let indicator = try #require(self.resolve(run: true, helpers: 4))
        #expect(indicator.helperRuns == 0 && indicator.badge == nil && indicator.label == "Moki is working")
    }

    @Test func sources() {
        #expect(self.resolve(run: true, companions: true)?.source == .companion)
        #expect(self.resolve(helpers: 2, companions: true)?.source == .companion)
        #expect(self.resolve(run: true)?.source == .emoji("🦞"))
        #expect(self.resolve(run: true, agent: AgentSummary(id: "coder", name: "forge"))?.source == .initials("F"))
        #expect(self.resolve(run: true, agent: AgentSummary(id: "coder", name: "Forge", emoji: " \n "))?.source == .initials("F"))
        #expect(self.resolve(run: true, agent: AgentSummary(id: "coder", name: "Forge", emoji: "  🛠️ "))?.source == .emoji("🛠️"))
    }

    @Test func blankNameFallsBackToAgentId() throws {
        let empty = try #require(self.resolve(run: true, agent: AgentSummary(id: "research", name: "")))
        #expect(empty.agentName == "research" && empty.label == "research is working" && empty.source == .initials("R"))
        let spaces = try #require(self.resolve(helpers: 1, agent: AgentSummary(id: "coder", name: "   ")))
        #expect(spaces.agentName == "coder" && spaces.label == "coder: 1 helper run working")
        #expect(self.resolve(run: true, agent: AgentSummary(id: "x", name: "  Moki  "))?.agentName == "Moki")
    }

    @Test func badgeCapsAtNinePlus() {
        #expect(self.resolve(helpers: 10)?.badge == "9+")
        #expect(self.resolve(helpers: 250)?.badge == "9+")
        #expect(self.resolve(helpers: 10)?.label == "Moki: 10 helper runs working")
    }

    @Test func negativeHelperCountIsNotWorking() {
        #expect(self.resolve(helpers: -1) == nil)
        #expect(self.resolve(helpers: -5, companions: true) == nil)
        #expect(self.resolve(run: true, helpers: -3)?.helperRuns == 0)
    }
}
