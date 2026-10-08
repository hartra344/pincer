import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

// #416: moving a chat into, out of or between groups under an agent re-files it at once, only once.

/// Each chat in the Mochi section, with the section it's listed under.
@MainActor
private func mochiPlacements(_ gateway: GatewayStore) -> [String: [String]] {
    guard let section = gateway.sections().first(where: { $0.kind == .agent("mochi") }) else { return [:] }
    var placements: [String: [String]] = [:]
    for channel in section.channels { placements[channel.id, default: []].append(section.id) }
    for sub in section.subsections {
        for channel in sub.channels { placements[channel.id, default: []].append(sub.id) }
    }
    return placements
}

@MainActor
func runDemoSidebarGroupMoves() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let utilities = "agent:mochi:dashboard:utilities"
    let packing = "agent:mochi:dashboard:packing"
    let connected = await waitFor("demo for group moves") {
        gateway.state.isConnected && gateway.sessions[utilities] != nil && gateway.groupCatalog.contains("Day of move")
    }
    check(connected, "group moves: demo connected")
    guard connected else { return }
    defer { gateway.stop() }
    gateway.organization = .agent
    let agent = "agent:mochi"
    let dayOfMove = "agent:mochi/group:Day of move"

    func expectOnce(_ key: String, in parent: String, _ label: String) async {
        let placed = await waitFor("group moves: \(label)") { mochiPlacements(gateway)[key] == [parent] }
        check(placed, "group moves: \(label) (\(mochiPlacements(gateway)[key] ?? []))")
        check(mochiPlacements(gateway).values.allSatisfy { $0.count == 1 }, "group moves: no chat listed twice after \(label)")
    }

    await expectOnce(utilities, in: agent, "Utilities starts ungrouped")
    // Into a group that already has a chat, right above it: the case #416 hit.
    await gateway.moveChat(utilities, toGroup: "Day of move", before: nil)
    await expectOnce(utilities, in: dayOfMove, "into a non-empty group")
    // Back out to the top of the ungrouped chats.
    if let section = gateway.sections().first(where: { $0.kind == .agent("mochi") }) {
        let moved = await gateway.moveToGroup(utilities, droppedOn: section)
        check(moved, "group moves: agent header drop accepted")
    }
    await expectOnce(utilities, in: agent, "out of a group")
    // Between groups.
    await gateway.moveChat(packing, toGroup: "Day of move", before: nil)
    await expectOnce(packing, in: dayOfMove, "between groups")
    // Into an empty group.
    let created = await gateway.createGroup("Unpacking")
    check(created, "group moves: empty group created")
    await gateway.moveChat(utilities, toGroup: "Unpacking", before: nil)
    await expectOnce(utilities, in: "agent:mochi/group:Unpacking", "into an empty group")

    // Grouping a home chat changes its By group placement/order, but By agent intentionally keeps
    // it in the agent's leading home slot, which is why its menu labels where groups appear.
    let home = "agent:mochi:main"
    let homeMoveReady = gateway.sessions[home] != nil && gateway.sessions[home]?.category == nil
    check(homeMoveReady, "group moves: demo home chat starts ungrouped")
    guard homeMoveReady else { return }
    await gateway.moveChat(home, toGroup: "Day of move", before: nil)
    let homeAssigned = await waitFor("home group assignment") {
        gateway.sessions[home]?.category == "Day of move" && gateway.groupOrder("Day of move").last == home
    }
    check(homeAssigned, "group moves: home chat keeps its assigned category and group order")
    check(mochiPlacements(gateway)[home] == [agent],
          "group moves: By agent keeps the assigned home chat in its leading position")
    gateway.organization = .group
    let visibleInGroup = gateway.sections().first { $0.kind == .group("Day of move") }?.channels.contains { $0.row.key == home } == true
    check(visibleInGroup, "group moves: assigned home chat is visible in its By group section")
}

// #948: a sub-session moved into a group is a regular top-level chat there; moving it back re-nests it.

@MainActor
func runSidebarSubSessionGroupChecks() {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Sub-sessions", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults)
    gateway.groupCatalog = ["Work"]
    let parent = "agent:main:dashboard:trip"
    let grouped = "agent:main:subagent:g"
    let nested = "agent:main:subagent:n"
    gateway.setSession(SessionRow(["key": .string(parent), "agentId": "main", "updatedAt": 3]), for: parent)
    for (key, category) in [(grouped, JSONValue.string("Work")), (nested, .null)] {
        var raw: [String: JSONValue] = ["key": .string(key), "agentId": "main", "unread": true, "updatedAt": 5,
                                        "spawnedBy": .string(parent), "parentSessionKey": .string(parent)]
        if !category.isNull { raw["category"] = category }
        gateway.setSession(SessionRow(.object(raw)), for: key)
    }
    check(gateway.sessions[grouped]?.isNestedHelper == false && gateway.sessions[nested]?.isNestedHelper == true,
          "sub-session grouping: isNestedHelper follows the category")
    check(gateway.nestingParent(of: grouped)?.key == parent && gateway.nestingParent(of: parent) == nil,
          "sub-session grouping: nestingParent finds the parent chat")
    let work = SidebarSection(id: "group:Work", title: "Work", emoji: nil, channels: [], kind: .group("Work"))
    check(gateway.groupDropValue(for: nested, onto: work) == .string("Work"),
          "sub-session grouping: dropping a sub-session on a group sets its category")
    check(gateway.groupOrder("Work") == [grouped], "sub-session grouping: group order includes the sub-session")
    check(gateway.totalUnread == 1, "sub-session grouping: only the grouped sub-session counts as unread")
    for organization in SidebarOrganization.allCases {
        gateway.organization = organization
        let channels = gateway.sections().flatMap(\.allChannels)
        check(channels.contains { $0.row.key == grouped } && !channels.contains { $0.row.key == nested },
              "sub-session grouping: \(organization) lists the grouped sub-session top-level, the other stays nested")
        check(channels.first { $0.row.key == parent }?.threads.map(\.key) == [nested],
              "sub-session grouping: \(organization) nests only the ungrouped sub-session under its parent")
    }
    #endif
}

@MainActor
func runDemoSubSessionGrouping() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let helper = DemoGateway.seededSubagents.done
    let parent = DemoGateway.subagentParentKey
    let connected = await waitFor("demo for sub-session grouping") {
        gateway.state.isConnected && gateway.sessions[helper] != nil && gateway.groupCatalog.contains("Day of move")
    }
    check(connected, "sub-session grouping: demo connected")
    guard connected else { return }
    defer { gateway.stop() }
    gateway.organization = .group
    let parentKey = gateway.sessions[helper]?.parentKey
    func channels() -> [SidebarChannel] { gateway.sections().flatMap(\.allChannels) }
    func nestedUnderParent() -> Bool { channels().first { $0.row.key == parent }?.threads.map(\.key).contains(helper) == true }
    check(parentKey == parent && nestedUnderParent(), "sub-session grouping: the helper starts nested under its parent")

    await gateway.moveChat(helper, toGroup: "Day of move", before: nil)
    let moved = await waitFor("helper grouped") {
        gateway.sessions[helper]?.category == "Day of move" && !nestedUnderParent()
    }
    check(moved, "sub-session grouping: the helper leaves its parent for the group")
    check(gateway.sessions[helper]?.parentKey == parentKey, "sub-session grouping: the parent link survives sessions.patch")
    let inGroup = gateway.sections().first { $0.kind == .group("Day of move") }?.channels.contains { $0.row.key == helper } == true
    check(inGroup, "sub-session grouping: the helper is a top-level chat in its group")

    await gateway.moveBackUnderParent(helper)
    let back = await waitFor("helper back under parent") { gateway.sessions[helper]?.category == nil && nestedUnderParent() }
    check(back, "sub-session grouping: moving back clears the category and re-nests the helper")
    check(gateway.sessions[helper]?.parentKey == parentKey, "sub-session grouping: the parent link is still intact")
}
