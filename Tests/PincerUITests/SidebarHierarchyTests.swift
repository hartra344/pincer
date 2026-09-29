import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #372: by-agent sidebar reads as agent → group → chat.
// Serialized: each test boots its own demo gateway, and CI runs the suites in parallel under load.
@Suite(.serialized)
@MainActor
struct SidebarHierarchyTests {
    private func connectedDemo(_ scratch: ScratchDefaults) async throws -> GatewayStore {
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        let ready = await eventually(timeout: .seconds(60)) {
            gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.agents.isEmpty
                && gateway.groupCatalog.contains("Day of move")
        }
        try #require(ready, "demo not ready: state=\(gateway.state) sessions=\(gateway.sessions.count) agents=\(gateway.agents.count) groups=\(gateway.groupCatalog)")
        gateway.organization = .agent
        return gateway
    }

    private func model(_ gateway: GatewayStore, collapsed: Set<String> = []) -> SidebarModel {
        SidebarModel.build(gateway: gateway, search: "", collapsed: collapsed, expandedThreads: [],
                           showSubagentRuns: false, showPreviews: false)
    }

    @Test func groupsNestUnderTheirAgent() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let model = self.model(gateway)

        let nested = model.groups.filter { !$0.subgroups.isEmpty }
        #expect(nested.count >= 2)
        for agent in model.groups {
            #expect(!agent.header.isSubsection)
            guard case let .agent(agentId) = agent.header.section.kind else { continue }
            for sub in agent.subgroups {
                #expect(sub.header.isSubsection)
                #expect(sub.header.section.kind == .agentGroup(agent: agentId, group: sub.header.section.title))
                #expect(sub.header.id == SidebarModel.headerId("agent:\(agentId)/group:\(sub.header.section.title)"))
                #expect(!sub.entries.isEmpty)
                #expect(sub.entries.allSatisfy { $0.row.agentId == agentId && $0.row.category == sub.header.section.title })
                #expect(sub.subgroups.isEmpty)
                #expect(sub.header.level == 1 && agent.header.level == 0)
                #expect(sub.header.chatCount == sub.header.section.channels.count && agent.header.chatCount == 0)
                #expect(sub.entries.allSatisfy { $0.depth == 1 && $0.groupName == sub.header.section.title })
                #expect(agent.header.agentAccessibilityLabel == "\(agent.header.section.title), agent")
                #expect(sub.header.agentAccessibilityLabel == nil)
            }
        }
    }

    @Test func mochiTreeOrder() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let mochi = try #require(self.model(gateway).groups.first { $0.header.section.kind == .agent("mochi") })
        #expect(mochi.subgroups.map(\.header.section.title) == ["Preparations", "Day of move"])
        #expect(mochi.subgroups.map(\.entries.count) == [2, 1])
        #expect(mochi.leadingEntries.count == 1)
        #expect(mochi.allHeaders.map(\.id) == [mochi.header.id] + mochi.subgroups.map(\.header.id))
        // Children list: home chat, then each group header followed by its chats, then ungrouped chats.
        let expected = mochi.leadingEntries.map(\.id)
            + mochi.subgroups.flatMap { [$0.header.id] + $0.entries.map(\.id) }
            + mochi.entries.map(\.id)
        #expect(mochi.childIds == expected)
        #expect(Set(mochi.allEntries.map(\.id)).count == mochi.allEntries.count)
        #expect(mochi.subgroups.first?.header.agentName == "Mochi")
        #expect(mochi.subgroups.map(\.header.subsectionAccessibilityLabel)
            == ["Preparations, group in Mochi, 2 chats", "Day of move, group in Mochi, 1 chat"])
        #expect((mochi.leadingEntries + mochi.entries).allSatisfy { $0.groupName == nil && $0.depth == 0 })
    }

    @Test func collapsingAGroupKeepsItsChatsInTheModelButFlagsTheHeader() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let groupId = "agent:mochi/group:Preparations"
        let mochi = try #require(self.model(gateway, collapsed: [groupId]).groups.first { $0.header.section.kind == .agent("mochi") })
        let prep = try #require(mochi.subgroups.first { $0.header.section.id == groupId })
        let move = try #require(mochi.subgroups.first { $0.header.section.title == "Day of move" })
        #expect(prep.header.isCollapsed && !move.header.isCollapsed && !mochi.header.isCollapsed)
        #expect(prep.header.accessibilityValue == L("Collapsed") && move.header.accessibilityValue == L("Expanded"))
        #expect(prep.header.accessibilityValue(isCollapsed: false) == L("Expanded"))
        #expect(prep.header.chatCount == 2)
        #expect(prep.entries.count == 2)

        let agentCollapsed = try #require(self.model(gateway, collapsed: ["agent:mochi"]).groups.first { $0.header.id == mochi.header.id })
        #expect(agentCollapsed.header.isCollapsed)
        #expect(agentCollapsed.subgroups.allSatisfy { !$0.header.isCollapsed })
    }

    @Test func collapsedHeaderAnnouncesUnreadCount() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = try await connectedDemo(scratch)
        defer { gateway.stop() }
        let groupId = "agent:mochi/group:Preparations"
        let mochi = try #require(self.model(gateway, collapsed: [groupId]).groups.first { $0.header.section.kind == .agent("mochi") })
        let prep = try #require(mochi.subgroups.first { $0.header.section.id == groupId })
        let unread = prep.entries.filter { $0.row.isUnread }.count
        #expect(prep.header.section.unreadCount == unread)
        let label = prep.header.subsectionAccessibilityLabel
        #expect(label.hasPrefix("Preparations, group in Mochi, 2 chats"))
        #expect(label.hasSuffix(", \(unread) unread") == (unread > 0))

        let open = try #require(self.model(gateway).groups.first { $0.header.section.kind == .agent("mochi") }?.subgroups.first)
        #expect(open.header.subsectionAccessibilityLabel == "Preparations, group in Mochi, 2 chats")
    }
}
