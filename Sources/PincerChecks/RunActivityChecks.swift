import Foundation
import PincerKit

// Live Activities for running agent turns (#50): what an activity says, and that a chat's run starts,
// updates and ends one. The iOS app shows them with ActivityKit; here a recording host stands in.

/// Remembers what the coordinator asked of its host, by chat.
@MainActor
private final class RecordingRunActivityHost: RunActivityHost {
    struct Ended {
        let state: RunActivityState
        let dismissAfter: TimeInterval
    }

    var keys: [String: String] = [:]
    var phases: [String: [RunActivityState.Phase]] = [:]
    var tools: [String: [String]] = [:]
    var starts: [String: Int] = [:]
    var ended: [String: Ended] = [:]
    var identities: [String: RunActivityIdentity] = [:]

    func start(_ identity: RunActivityIdentity, state: RunActivityState) -> String? {
        let id = "check-\(self.keys.count + 1)"
        self.keys[id] = identity.sessionKey
        self.identities[identity.sessionKey] = identity
        self.starts[identity.sessionKey, default: 0] += 1
        self.ended[identity.sessionKey] = nil
        self.record(id, state)
        return id
    }

    func update(id: String, state: RunActivityState) { self.record(id, state) }

    func end(id: String, state: RunActivityState, dismissAfter: TimeInterval) {
        self.record(id, state)
        if let key = self.keys[id] { self.ended[key] = Ended(state: state, dismissAfter: dismissAfter) }
    }

    private func record(_ id: String, _ state: RunActivityState) {
        guard let key = self.keys[id] else { return }
        if self.phases[key]?.last != state.phase { self.phases[key, default: []].append(state.phase) }
        if let tool = state.toolName { self.tools[key, default: []].append(tool) }
    }

    func forget(_ key: String) {
        self.phases[key] = nil
        self.tools[key] = nil
        self.starts[key] = nil
        self.ended[key] = nil
    }
}

private func describe(_ phases: [RunActivityState.Phase]?) -> String {
    (phases ?? []).map(\.rawValue).joined(separator: " → ")
}

private func inOrder(_ seen: [RunActivityState.Phase]?, _ expected: [RunActivityState.Phase]) -> Bool {
    let seen = seen ?? []
    var index = seen.startIndex
    for phase in expected {
        guard let found = seen[index...].firstIndex(of: phase) else { return false }
        index = seen.index(after: found)
    }
    return true
}

@MainActor
func checkRunActivityState() {
    print("Live Activity state")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func running(_ signals: AvatarSignals) -> RunActivityState { RunActivityState.running(signals, startedAt: start) }

    check(running(AvatarSignals(isRunning: true)).phase == .thinking, "activity: a run with nothing more specific is thinking")
    check(running(AvatarSignals(isRunning: true, isCompacting: true)).phase == .compacting, "activity: compaction")
    check(running(AvatarSignals(isRunning: true, isStreaming: true)).phase == .replying, "activity: streamed text is replying")
    let tool = running(AvatarSignals(isRunning: true, isStreaming: true, runningToolName: "exec"))
    check(tool.phase == .tool && tool.toolName == "exec" && tool.status == "Running exec" && tool.startedAt == start,
          "activity: a running tool beats replying (\(tool.status))")
    let waiting = running(AvatarSignals(isRunning: true, runningToolName: "exec", awaitingApproval: true))
    check(waiting.phase == .awaitingApproval && waiting.status == "Waiting for your approval" && waiting.toolName == nil,
          "activity: waiting for approval beats a tool")
    check(running(AvatarSignals(isRunning: true, runningToolName: "mcp__github__create_issue")).toolName == "create_issue",
          "activity: an MCP tool is shown without its server")

    let end = start.addingTimeInterval(75)
    let done = RunActivityState.finished(tool, outcome: .success, at: end)
    check(done.phase == .completed && done.endedAt == end && done.toolName == nil && done.phase.isFinal,
          "activity: success finishes as completed")
    check(RunActivityState.finished(tool, outcome: .error, at: end).phase == .failed, "activity: an error finishes as failed")
    check(RunActivityState.finished(tool, outcome: .none, at: end).phase == .stopped, "activity: a stopped run finishes as stopped")
    check(!tool.phase.isFinal && tool.endedAt == nil, "activity: a running turn isn't final")

    let decoded = try? JSONDecoder().decode(RunActivityState.self, from: JSONEncoder().encode(done))
    check(decoded == done, "activity: state round-trips through Codable (it's the ActivityKit content state)")

    let gatewayId = UUID()
    let route = PincerRoute(target: Notifier.Target(gatewayId: gatewayId, sessionKey: "agent:main:main"))
    let identity = RunActivityIdentity(gatewayId: gatewayId, sessionKey: "agent:main:main", agentName: "Moki", chatTitle: "Main",
                                       emoji: "🦞", url: route.url)
    let identityBack = try? JSONDecoder().decode(RunActivityIdentity.self, from: JSONEncoder().encode(identity))
    check(identityBack == identity && PincerRoute(url: identity.url)?.sessionKey == "agent:main:main",
          "activity: the identity round-trips and its link opens the chat")

    let coordinator = RunActivityCoordinator.shared
    check(!coordinator.isActive, "activity: nothing is shown until a host is installed")
}

/// A demo run starts a card, follows its tool and reply, and ends it; failures, stops and approvals show too.
@MainActor
func runDemoRunActivity() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for live activities") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for live activities connected")
    guard connected else { return }
    let coordinator = RunActivityCoordinator.shared
    let host = RecordingRunActivityHost()
    coordinator.host = host
    coordinator.startDelay = 0
    defer {
        coordinator.host = nil
        coordinator.startDelay = RunActivityCoordinator.defaultStartDelay
        UserDefaults.standard.removeObject(forKey: RunActivityCoordinator.enabledKey)
        gateway.stop()
    }

    let key = "agent:research:main"
    let scout = gateway.chat(for: key)
    await scout.load()
    _ = await waitFor("research history") { scout.hasLoaded }

    // A turn that uses a tool: the card starts, shows the tool and the reply, then completes.
    _ = await scout.send("check the disk with a tool")
    let toolDone = await waitFor("tool run to end its activity", timeout: 30) { host.ended[key] != nil }
    check(toolDone && host.starts[key] == 1, "tool run: one activity started (\(host.starts[key] ?? 0))")
    check(inOrder(host.phases[key], [.tool, .replying, .completed]),
          "tool run: tool → replying → completed (\(describe(host.phases[key])))")
    check(host.tools[key]?.contains("exec") == true, "tool run: the card names the tool (\(host.tools[key] ?? []))")
    if let ended = host.ended[key], let endedAt = ended.state.endedAt {
        check(ended.state.phase == .completed && endedAt >= ended.state.startedAt
              && ended.dismissAfter == RunActivityCoordinator.finishedDismissDelay,
              "tool run: ends as completed and lingers (\(ended.dismissAfter)s)")
    } else {
        check(false, "tool run: ended with an end time")
    }
    check(host.identities[key]?.agentName == gateway.agent("research").name
          && PincerRoute(url: host.identities[key]?.url ?? URL(fileURLWithPath: "/"))?.sessionKey == key,
          "tool run: the card names the agent and links to the chat")
    check(coordinator.activityId(gatewayId: gateway.id, sessionKey: key) == nil, "tool run: nothing left showing")

    // A failing run ends as failed.
    host.forget(key)
    _ = await scout.send("please fail this time")
    let failed = await waitFor("failing run to end its activity", timeout: 20) { host.ended[key] != nil }
    check(failed && host.ended[key]?.state.phase == .failed, "failing run: ends as failed (\(describe(host.phases[key])))")

    // Stopping a run dismisses its card at once.
    host.forget(key)
    _ = await scout.send("tell me a long story")
    _ = await waitFor("long story to begin its activity", timeout: 10) { host.starts[key] == 1 }
    await scout.abort()
    let stopped = await waitFor("stopped run to end its activity", timeout: 10) { host.ended[key] != nil }
    check(stopped && host.ended[key]?.state.phase == .stopped && host.ended[key]?.dismissAfter == 0,
          "stopped run: ends as stopped and goes at once (\(describe(host.phases[key])))")
    _ = await waitFor("stopped run to settle", timeout: 10) { !scout.isRunning }

    // The setting off: no card for a run.
    host.forget(key)
    coordinator.isEnabled = false
    _ = await scout.send("check the disk with a tool")
    _ = await waitFor("run to begin with activities off", timeout: 5) { scout.isRunning }
    _ = await waitFor("run to end with activities off", timeout: 20) { !scout.isRunning }
    check(host.starts[key] == nil, "setting off: a run starts no activity")
    UserDefaults.standard.removeObject(forKey: RunActivityCoordinator.enabledKey)
    check(coordinator.isEnabled, "setting off: activities are on unless switched off")

    // A command waiting for approval shows on the card.
    let claw = gateway.chat(for: "agent:main:dashboard:trip")
    let clawKey = claw.sessionKey
    await claw.load()
    _ = await waitFor("trip history") { claw.hasLoaded }
    let known = Set(gateway.approvals.map(\.id))
    _ = await claw.send("please approve this")
    let approved = await waitFor("approval run to end its activity", timeout: 20) { host.ended[clawKey] != nil }
    check(approved && host.phases[clawKey]?.contains(.awaitingApproval) == true,
          "approve: the card waits for approval (\(describe(host.phases[clawKey])))")
    if let approval = gateway.approvals.first(where: { !known.contains($0.id) }) {
        await gateway.resolveApproval(approval, decision: "deny")
    }
}
