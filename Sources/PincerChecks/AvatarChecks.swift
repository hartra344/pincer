import Foundation
import PincerKit

// Animated agent avatar (#75): the demo's seeded chats and triggers drive every avatar state, and
// its agents get distinct identities (agent.identity.get) and seeded styles.

@MainActor
private func avatarState(_ chat: ChatStore, at date: Date = Date()) -> AvatarState {
    AvatarStateMachine.state(for: chat.avatarSignals, now: date)
}

/// Polls the chat's avatar state until `done` holds, recording each change in order.
@MainActor
private func watchAvatar(_ chat: ChatStore, timeout: Double = 20, until done: (AvatarState) -> Bool) async -> [AvatarState] {
    var seen: [AvatarState] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let state = avatarState(chat)
        if seen.last != state { seen.append(state) }
        if done(state) { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return seen
}

private func describe(_ states: [AvatarState]) -> String {
    states.map { state in
        if case let .tool(tool) = state { return "tool(\(tool.rawValue))" }
        return "\(state)"
    }.joined(separator: " → ")
}

/// Whether `expected` appears in `seen` in order (other states may sit between).
private func inOrder(_ seen: [AvatarState], _ expected: [AvatarState]) -> Bool {
    var index = seen.startIndex
    for state in expected {
        guard let found = seen[index...].firstIndex(of: state) else { return false }
        index = seen.index(after: found)
    }
    return true
}

/// `agent.identity.get` over a raw connection: by id, by session key, the default, and an unknown agent.
@MainActor
func checkAgentIdentities(profile: GatewayProfile, agents: [AgentSummary], label: String) async {
    let connection = GatewayConnection(profile: profile)
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    guard await waitFor("\(label) raw connection for identities", timeout: 25, { ready.value }) else {
        check(false, "\(label) raw connection for identities")
        return
    }
    for agent in agents {
        let identity = try? await connection.request("agent.identity.get", ["agentId": .string(agent.id)])
        check(identity?["agentId"]?.string == agent.id && identity?["name"]?.string == agent.name
              && identity?["emoji"]?.string == agent.emoji && identity?["avatar"]?.string == agent.emoji,
              "\(label) agent.identity.get \(agent.id) matches agents.list (\(identity.map { "\($0)" } ?? "nil"))")
    }
    let bySession = try? await connection.request("agent.identity.get", ["sessionKey": "agent:coder:main"])
    check(bySession?["agentId"]?.string == "coder" && bySession?["name"]?.string == "Forge",
          "\(label) agent.identity.get resolves a session key's agent")
    let byDefault = try? await connection.request("agent.identity.get", [:])
    check(byDefault?["agentId"]?.string == "main", "\(label) agent.identity.get defaults to the main agent")
}

@MainActor
func runDemoAvatars() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for avatars") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for avatars connected")
    guard connected else { return }
    defer { gateway.stop() }

    // Distinct identities, from agents.list and agent.identity.get, and distinct seeded companions.
    let agents = gateway.agents
    check(agents.count == 4 && Set(agents.map(\.name)).count == 4 && Set(agents.compactMap(\.emoji)).count == 4,
          "demo agents have distinct names and emoji (\(agents.map { "\($0.name) \($0.emoji ?? "-")" }))")
    await checkAgentIdentities(profile: .demo(), agents: agents, label: "demo")
    let styles = agents.map { AvatarStyle.seeded(from: AvatarStyle.identitySeed(name: $0.name, agentId: $0.id)) }
    check(Set(styles).count == agents.count, "demo agents get distinct seeded styles (\(styles.map { "\($0.creature)/\($0.accessory)/\($0.palette)" }))")
    check(Set(styles.map(\.creature)).count > 1, "demo agents with distinct names aren't all the same creature (\(styles.map(\.creature)))")
    let idStyles = agents.map { AvatarStyle.seeded(from: $0.id) }
    check(Set(idStyles).count == agents.count, "demo agent ids seed distinct styles too")

    // Seeded chats: Forge waits on the seeded push approval; everyone else rests.
    let forge = gateway.chat(for: "agent:coder:main")
    check(avatarState(forge) == .awaitingApproval, "Forge's main chat waits for the seeded approval (\(avatarState(forge)))")
    for key in ["agent:main:main", "agent:research:main", "agent:research:dashboard:papers", "agent:main:dashboard:trip"] {
        let chat = gateway.chat(for: key)
        check(avatarState(chat) == .idle, "\(key) avatar is idle at launch (\(avatarState(chat)))")
    }

    // A tool run: thinking → exec tool → streaming → success → idle.
    let scout = gateway.chat(for: "agent:research:main")
    await scout.load()
    _ = await waitFor("research history") { scout.hasLoaded }
    _ = await scout.send("check the disk with a tool")
    let toolRun = await watchAvatar(scout, timeout: 30) { $0 == .success }
    check(inOrder(toolRun, [.thinking, .tool(.exec), .streaming, .success]),
          "tool run: thinking → tool(exec) → streaming → success (\(describe(toolRun)))")
    check(!toolRun.contains(.error) && !toolRun.contains(.awaitingApproval), "tool run shows no error or approval")
    let rested = await watchAvatar(scout, timeout: AvatarStateMachine.successDuration + 3) { $0 == .idle }
    check(rested.last == .idle, "success fades back to idle (\(describe(rested)))")
    if let at = scout.avatarSignals.outcomeAt {
        check(AvatarStateMachine.nextTransition(for: scout.avatarSignals, now: Date()) == nil
              && at.timeIntervalSinceNow <= -AvatarStateMachine.successDuration, "no transition pending once success expires")
    }

    // A failing run: thinking → error → idle.
    _ = await scout.send("please fail this time")
    let failed = await watchAvatar(scout, timeout: 20) { $0 == .error }
    check(inOrder(failed, [.thinking, .error]), "failing run: thinking → error (\(describe(failed)))")
    check(scout.avatarSignals.lastOutcome == .error && !scout.avatarSignals.isRunning, "failed run records an error outcome")
    let recovered = await watchAvatar(scout, timeout: AvatarStateMachine.errorDuration + 3) { $0 == .idle }
    check(recovered.last == .idle, "error fades back to idle (\(describe(recovered)))")

    // /compact: compacting, then success.
    _ = await scout.send("/compact")
    let compacted = await watchAvatar(scout, timeout: 20) { $0 == .success }
    check(inOrder(compacted, [.compacting, .success]), "/compact: compacting → success (\(describe(compacted)))")
    _ = await watchAvatar(scout, timeout: AvatarStateMachine.successDuration + 3) { $0 == .idle }

    // approve: awaiting approval until it's answered, whatever the run is doing.
    let claw = gateway.chat(for: "agent:main:dashboard:trip")
    await claw.load()
    _ = await waitFor("trip history") { claw.hasLoaded }
    let known = Set(gateway.approvals.map(\.id))
    _ = await claw.send("please approve this")
    let asked = await watchAvatar(claw, timeout: 10) { $0 == .awaitingApproval }
    check(asked.last == .awaitingApproval, "approve: awaiting approval (\(describe(asked)))")
    check(avatarState(forge) == .awaitingApproval, "Forge still waits on its own approval")
    let finished = await waitFor("approval run to finish", timeout: 20) { !claw.isRunning }
    check(finished && avatarState(claw) == .awaitingApproval, "a finished run still waits while its approval is pending")
    if let approval = gateway.approvals.first(where: { !known.contains($0.id) }) {
        await gateway.resolveApproval(approval, decision: "deny")
        let cleared = await watchAvatar(claw, timeout: 5) { $0 != .awaitingApproval }
        check(cleared.last != .awaitingApproval, "answering the approval clears it (\(describe(cleared)))")
    } else {
        check(false, "approve raised an approval for the trip chat")
    }
    check(avatarState(forge) == .awaitingApproval, "the seeded approval is untouched")
    if let seeded = gateway.approvals.first(where: { $0.sessionKey == "agent:coder:main" }) {
        await gateway.resolveApproval(seeded, decision: "allow-once")
        let released = await watchAvatar(forge, timeout: 5) { $0 != .awaitingApproval }
        check(released.last == .idle, "Forge rests once the seeded push is approved (\(describe(released)))")
    }

    // Aborted: neither a success nor an error.
    _ = await scout.send("tell me a long story")
    _ = await watchAvatar(scout, timeout: 10) { $0 == .streaming }
    await scout.abort()
    let stopped = await watchAvatar(scout, timeout: 10) { $0 == .idle }
    check(stopped.last == .idle && !stopped.contains(.success) && !stopped.contains(.error),
          "aborted run goes straight back to idle (\(describe(stopped)))")
}

/// The same avatar states against the mock Gateway's events.
@MainActor
func runLiveAvatars(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock avatars", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor("mock for avatars", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "mock for avatars connected")
    guard connected else { return }
    defer { gateway.stop() }

    await checkAgentIdentities(profile: profile, agents: gateway.agents, label: "mock")

    let chat = gateway.chat(for: "agent:research:main")
    await chat.load()
    _ = await waitFor("mock research history") { chat.hasLoaded }
    check(avatarState(chat) == .idle, "mock research avatar idle before a run (\(avatarState(chat)))")

    _ = await chat.send("run a tool please")
    let toolRun = await watchAvatar(chat, timeout: 30) { $0 == .success }
    check(inOrder(toolRun, [.thinking, .tool(.exec), .streaming, .success]),
          "mock tool run: thinking → tool(exec) → streaming → success (\(describe(toolRun)))")
    _ = await watchAvatar(chat, timeout: AvatarStateMachine.successDuration + 3) { $0 == .idle }

    _ = await chat.send("break it [mock:fail-run]")
    let failed = await watchAvatar(chat, timeout: 20) { $0 == .error }
    check(inOrder(failed, [.thinking, .error]), "mock failing run: thinking → error (\(describe(failed)))")
    let recovered = await watchAvatar(chat, timeout: AvatarStateMachine.errorDuration + 3) { $0 == .idle }
    check(recovered.last == .idle, "mock error fades back to idle (\(describe(recovered)))")

    let known = Set(gateway.approvals.map(\.id))
    _ = await chat.send("please approve this")
    let asked = await watchAvatar(chat, timeout: 10) { $0 == .awaitingApproval }
    check(asked.last == .awaitingApproval, "mock approve: awaiting approval (\(describe(asked)))")
    _ = await waitFor("mock approval run to finish", timeout: 20) { !chat.isRunning }
    if let approval = gateway.approvals.first(where: { !known.contains($0.id) }) {
        await gateway.resolveApproval(approval, decision: "deny")
        let cleared = await watchAvatar(chat, timeout: 5) { $0 != .awaitingApproval }
        check(cleared.last != .awaitingApproval, "mock answering the approval clears it (\(describe(cleared)))")
    } else {
        check(false, "mock approve raised an approval")
    }
    _ = await watchAvatar(chat, timeout: AvatarStateMachine.successDuration + 3) { $0 == .idle }

    _ = await chat.send("/compact")
    let compacted = await watchAvatar(chat, timeout: 20) { $0 == .success }
    check(inOrder(compacted, [.compacting, .success]), "mock /compact: compacting → success (\(describe(compacted)))")
}
