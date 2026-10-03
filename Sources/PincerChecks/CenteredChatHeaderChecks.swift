import Foundation
@testable import PincerKit

@MainActor
func runCenteredChatHeaderChecks() {
    for state in [AvatarState.idle, .thinking, .awaitingApproval, .error] {
        let early = AvatarMotion.pose(for: state, time: 0, elapsed: 0, animated: false)
        let later = AvatarMotion.pose(for: state, time: 1000, elapsed: 1000, animated: false)
        check(early == later && early == AvatarMotion.keyPose(for: state),
              "chat identity: still \(state) pose preserves activity without an animation clock")
    }
}

@MainActor
func runDemoCenteredChatHeaderChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let trip = "agent:main:dashboard:trip", garden = "agent:main:dashboard:garden"
    guard await waitFor("centered identity Demo", timeout: 25, {
        gateway.state.isConnected && gateway.sessions[trip] != nil && gateway.sessions[garden] != nil
    }) else { check(false, "chat identity: actual seeded Demo connects"); return }
    var titles: [String] = []
    for key in [trip, garden, trip] {
        gateway.selectedKey = key
        let chat = gateway.chat(for: key)
        await chat.load()
        await chat.refreshBranches()
        guard let row = gateway.sessions[key] else {
            check(false, "chat identity: selected seeded chat has its actual current title"); return
        }
        let title = row.title
        titles.append(title)
        gateway.rememberTitle(title, for: key)
        check(gateway.cachedTitle(for: key) == title && !title.isEmpty,
              "chat identity: real header rememberTitle entry point retains the selected Demo title")
        check(gateway.agent(row.agentId).id == "main",
              "chat identity: selected seeded chat resolves its actual agent avatar")
        check(chat.hasLoaded && !chat.branches.isEmpty,
              "chat identity: moving controls into overflow preserves real loaded branch metadata")
    }
    check(titles[0] == titles[2] && titles[0] != titles[1],
          "chat identity: switching away and back retains each chat's meaningful identity")
    check(gateway.chat(for: garden).branchHeaderChip != nil,
          "chat identity: seeded Garden retains actual alternate branches for overflow")
    let running = "agent:research:dashboard:launch-plan"
    check(gateway.subagentTree(rootKey: running).runningCount > 0,
          "chat identity: existing seeded running helpers remain available to Runs")
}
