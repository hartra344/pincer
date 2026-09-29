import Foundation
import PincerKit

// #236: by-agent sidebar nests each agent's groups under the agent.

/// The demo's Mochi moving-planner agent: home chat, "Preparations" and "Day of move" groups, one ungrouped chat.
@MainActor
func runDemoSidebarAgentGroups() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for agent groups") {
        gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.agents.isEmpty
    }
    check(connected, "demo for agent groups connected")
    guard connected else { return }
    defer { gateway.stop() }

    let catalog = await waitFor("demo group catalog") { gateway.groupCatalog.contains("Day of move") }
    check(catalog, "agent groups: demo group catalog loaded (\(gateway.groupCatalog))")
    func mochi() -> SidebarSection? { gateway.sections().first { $0.kind == .agent("mochi") } }

    gateway.organization = .group
    check(gateway.sections().allSatisfy { $0.subsections.isEmpty }, "agent groups: by-group mode has no nested subsections")
    gateway.organization = .agent
    guard let section = mochi() else {
        check(false, "agent groups: demo has a Mochi agent section (\(gateway.sections().map(\.id)))")
        return
    }
    check(section.title == "Mochi", "agent groups: section titled Mochi (\(section.title))")
    check(section.leadingChannelCount == 1 && section.channels.first?.row.isMain == true,
          "agent groups: Mochi's home chat leads (\(section.channels.map(\.id)))")
    check(section.subsections.map(\.title) == ["Preparations", "Day of move"],
          "agent groups: subsections in group order (\(section.subsections.map(\.title)))")
    check(section.subsections.map(\.id) == ["agent:mochi/group:Preparations", "agent:mochi/group:Day of move"],
          "agent groups: subsection ids (\(section.subsections.map(\.id)))")
    check(section.subsections.first?.channels.count == 2 && section.subsections.last?.channels.count == 1,
          "agent groups: Preparations has 2 chats, Day of move has 1")
    let ungrouped = Array(section.channels.dropFirst(section.leadingChannelCount))
    check(ungrouped.count == 1 && ungrouped.allSatisfy { $0.row.category == nil }, "agent groups: one ungrouped chat (\(ungrouped.map(\.id)))")
    let expected = section.channels.prefix(section.leadingChannelCount).map(\.id)
        + section.subsections.flatMap { $0.channels.map(\.id) } + ungrouped.map(\.id)
    check(section.allChannels.map(\.id) == expected && Set(expected).count == 5,
          "agent groups: order is home → Preparations → Day of move → ungrouped (\(section.allChannels.map(\.id)))")
    check(section.allChannels.allSatisfy { $0.row.agentId == "mochi" }, "agent groups: only Mochi's chats")

    // Search hides empty subsections.
    let movers = gateway.sections(search: "movers").first { $0.kind == .agent("mochi") }
    check(movers?.subsections.map(\.title) == ["Day of move"], "agent groups: search keeps only matching groups")

    guard let prep = section.subsections.first, let move = section.subsections.last,
          let inPrep = prep.channels.first, let inMove = move.channels.first, let loose = ungrouped.first,
          let home = section.channels.first
    else { return }
    check(gateway.groupDropValue(for: inPrep.id, onto: prep) == nil, "agent groups: dropping onto own group is a no-op")
    check(gateway.groupDropValue(for: inPrep.id, onto: move) == .string("Day of move"), "agent groups: move between groups")
    check(gateway.groupDropValue(for: home.id, onto: prep) == .string("Preparations"), "agent groups: home chat can join a group")
    check(gateway.groupDropValue(for: loose.id, onto: prep) == .string("Preparations"), "agent groups: ungrouped chat can join a group")
    check(gateway.groupDropValue(for: inPrep.id, onto: section) == .null, "agent groups: agent header ungroups a grouped chat")
    check(gateway.groupDropValue(for: loose.id, onto: section) == nil, "agent groups: agent header ignores an ungrouped chat")
    let foreign = SidebarSection(id: "agent:main/group:Preparations", title: "Preparations", emoji: nil, channels: [],
                                 kind: .agentGroup(agent: "main", group: "Preparations"))
    check(gateway.groupDropValue(for: loose.id, onto: foreign) == nil, "agent groups: cross-agent drop is rejected")
    if let other = gateway.sessions.values.first(where: { $0.agentId != "mochi" && !$0.isSubagent }) {
        check(gateway.groupDropValue(for: other.key, onto: prep) == nil, "agent groups: another agent's chat can't join Mochi's group")
        let refused = await gateway.moveToGroup(other.key, droppedOn: prep)
        check(!refused, "agent groups: cross-agent moveToGroup refused")
    }

    // Drop onto own agent's subsection.
    let accepted = await gateway.moveToGroup(loose.id, droppedOn: prep)
    check(accepted, "agent groups: moveToGroup accepted")
    let moved = await waitFor("chat moved into Preparations") { gateway.sessions[loose.id]?.category == "Preparations" }
    check(moved && gateway.sessions[loose.id]?.agentId == "mochi", "agent groups: category set, agent unchanged")
    let after = mochi()
    check(after?.subsections.first?.channels.map(\.id).contains(loose.id) == true
          && after?.channels.count == section.leadingChannelCount, "agent groups: chat now listed under Preparations")

    // Drag it back to the agent header.
    if let after {
        let unset = await gateway.moveToGroup(loose.id, droppedOn: after)
        check(unset, "agent groups: agent header drop accepted")
        let back = await waitFor("chat ungrouped") { gateway.sessions[loose.id]?.category == nil }
        check(back, "agent groups: dropping on the agent ungroups")
    }
    _ = inMove
}
