import Foundation
import PincerKit

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
}
