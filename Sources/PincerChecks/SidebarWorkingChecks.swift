import Foundation
import PincerKit

// Sidebar working indicator (#177): a working chat's row shows its agent's avatar dancing in place
// of the spinner, with a label naming the agent and a badge for hidden helper runs.

@MainActor
func checkSidebarWorking() {
    print("Sidebar working avatar")
    let moki = AgentSummary(id: "main", name: "Moki", emoji: "🦞")
    func resolve(_ run: Bool, _ helpers: Int, listed: Bool = false, agent: AgentSummary = moki,
                 companions: Bool = false) -> SidebarWorkingIndicator?
    {
        SidebarWorkingIndicator.resolve(hasActiveRun: run, runningSubagents: helpers, showSubagentRuns: listed,
                                        agent: agent, companionsEnabled: companions)
    }

    check(resolve(false, 0) == nil && resolve(false, 0, listed: true) == nil, "sidebar working: idle rows show nothing")
    let own = resolve(true, 0)
    check(own?.label == "Moki is working" && own?.source == .emoji("🦞") && own?.helperRuns == 0 && own?.badge == nil,
          "sidebar working: own run (\(own?.label ?? "nil"))")
    let hidden = resolve(false, 2)
    check(hidden?.helperRuns == 2 && hidden?.badge == "2" && hidden?.label == "Moki: 2 helper runs working",
          "sidebar working: hidden helper runs badge the parent (\(hidden?.label ?? "nil"))")
    check(resolve(false, 1)?.label == "Moki: 1 helper run working", "sidebar working: one helper run")
    check(resolve(false, 3, listed: true) == nil, "sidebar working: listed helper runs don't mark the parent")
    check(resolve(true, 5)?.helperRuns == 0 && resolve(true, 5)?.label == "Moki is working", "sidebar working: own run wins over helpers")
    check(resolve(true, 0, companions: true)?.source == .companion, "sidebar working: companions on dances the pet")
    check(resolve(true, 0, agent: AgentSummary(id: "coder", name: "forge"))?.source == .initials("F")
          && resolve(true, 0, agent: AgentSummary(id: "coder", name: "Forge", emoji: "  "))?.source == .initials("F"),
          "sidebar working: no emoji falls back to the initial")
    let unnamed = resolve(true, 0, agent: AgentSummary(id: "research", name: " "))
    check(unnamed?.agentName == "research" && unnamed?.label == "research is working", "sidebar working: blank name uses the agent id")
    check(resolve(false, 10)?.badge == "9+" && resolve(false, 9)?.badge == "9", "sidebar working: badge caps at 9+")
    check(resolve(false, -2) == nil, "sidebar working: a negative helper count isn't working")
}

/// The demo opens with Forge at work in "Fix retry backoff" and a Scout helper run under "Paper digest".
@MainActor
func runDemoSidebarWorking() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for sidebar working") {
        gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.agents.isEmpty
    }
    check(connected, "demo for sidebar working connected")
    guard connected else { return }
    defer { gateway.stop() }

    let channels = gateway.sections().flatMap(\.channels)
    func indicator(_ key: String, listed: Bool = false, companions: Bool = false) -> SidebarWorkingIndicator? {
        guard let channel = channels.first(where: { $0.row.key == key }) else { return nil }
        let row = channel.row
        let helpers = channel.threads.filter { $0.isSubagent && $0.hasActiveRun }.count
        return SidebarWorkingIndicator.resolve(hasActiveRun: row.hasActiveRun, runningSubagents: helpers,
                                               showSubagentRuns: listed, agent: gateway.agent(row.agentId),
                                               companionsEnabled: companions)
    }

    let retryFix = "agent:coder:dashboard:retry-fix"
    let working = indicator(retryFix)
    let forge = gateway.agent("coder")
    check(gateway.sessions[retryFix]?.hasActiveRun == true && working != nil && working?.agentId == "coder"
          && working?.label.contains(forge.name) == true && working?.source == forge.emoji.map { .emoji($0) }
          && working?.badge == nil,
          "demo: Forge's Fix retry backoff chat is working at launch (\(working?.label ?? "nil"))")
    check(indicator(retryFix, companions: true)?.source == .companion, "demo: with companions on, Forge's pet dances")

    let papers = "agent:research:dashboard:papers"
    let helper = indicator(papers)
    let scout = gateway.agent("research")
    check(gateway.sessions[papers]?.hasActiveRun == false && helper?.helperRuns == 1 && helper?.badge == "1"
          && helper?.label == "\(scout.name): 1 helper run working",
          "demo: Paper digest's running helper badges Scout (\(helper?.label ?? "nil"))")
    check(indicator(papers, listed: true) == nil, "demo: with helper runs listed, Paper digest isn't working")

    let idle = ["agent:main:main", "agent:research:main", "agent:coder:main", "agent:main:dashboard:trip"]
    check(idle.allSatisfy { indicator($0) == nil }, "demo: the other seeded chats are idle")

    // Stopping a seeded run ends it like any other.
    let chat = gateway.chat(for: retryFix)
    check(chat.isRunning, "demo: the seeded run reads as running in its chat")
    await chat.abort()
    let stopped = await waitFor("seeded run stopped") { gateway.sessions[retryFix]?.hasActiveRun == false && !chat.isRunning }
    check(stopped, "demo: stopping the seeded run ends it")
}
