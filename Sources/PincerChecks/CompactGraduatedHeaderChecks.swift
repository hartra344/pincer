import Foundation
@testable import PincerKit

@MainActor
func runCompactGraduatedHeaderChecks() {
    let standard = CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22)
    let accessible = CompactChatHeaderLayout.reservation(measuredTitleHeight: 76, scaledTitleAllowance: 48)
    check(standard == 44 && CompactChatHeaderLayout.avatarSize == 48,
          "actual compact header policy reduces avatar and default reservation")
    check(accessible > standard && CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22) == standard,
          "actual finished-title policy expands and shrinks without accumulating height")
    check(CompactChatHeaderLayout.backdrop(reduceTransparency: true) == .opaque,
          "actual compact backdrop policy honors Reduce Transparency")
}

@MainActor
func runDemoCompactGraduatedHeaderChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let trip = "agent:main:dashboard:trip", garden = "agent:main:dashboard:garden"
    guard await waitFor("compact graduated header Demo", timeout: 25, {
        gateway.state.isConnected && gateway.sessions[trip] != nil && gateway.sessions[garden] != nil
    }) else { check(false, "actual compact header Demo connects"); return }
    var titles: [String] = []
    for key in [trip, garden, trip] {
        gateway.selectedKey = key
        let chat = gateway.chat(for: key)
        await chat.load()
        guard let row = gateway.sessions[key] else { check(false, "actual compact header session remains available"); return }
        titles.append(row.title)
        check(!row.title.isEmpty && gateway.agent(row.agentId).id == "main" && chat.hasLoaded,
              "actual seeded compact header preserves selected chat title and animated-agent identity")
    }
    check(titles[0] == titles[2] && titles[0] != titles[1], "actual compact header source switches away and back without identity leakage")
    runCompactGraduatedHeaderChecks()
}
