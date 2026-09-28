import Foundation
import PincerKit

// Messages from another agent or an automation, end to end (#207): the demo's and the mock's
// `chat.history` through GatewayStore and ChatStore, as the chat view gets them.

/// The seeded exchange in Claw's main chat, by transcript id.
private struct ForwardedSeed {
    var intro: String
    var reply: String
    var thanks: String
    var note: String
    var you: String
}

/// Checks the loaded exchange: Kiko, Claw, Kiko, Claw, then you, each in its own group.
@MainActor
private func checkForwardedExchange(_ gateway: GatewayStore, _ chat: ChatStore, _ seed: ForwardedSeed, label: String) {
    let agents = gateway.agents
    let claw = agents.first { $0.id == "main" }?.name ?? "Claw"
    check(agents.contains { $0.id == "kiko" && $0.name == "Kiko" }, "\(label): Kiko is on the roster (\(agents.map(\.name)))")

    let intro = chat.message(withId: seed.intro)
    check(intro?.role == .assistant && intro?.sender?.kind == .agent && intro?.sender?.agentId == "kiko"
          && intro?.sender?.sessionKey == "agent:kiko:main", "\(label): Kiko's intro is attributed to Kiko (\(String(describing: intro?.sender)))")
    check(intro?.plainText.hasPrefix("Hi Claw! I'm Kiko") == true && intro?.plainText.contains("[Inter-session message]") == false,
          "\(label): Kiko's text is shown as she wrote it")
    check(chat.message(withId: seed.reply)?.sender == nil && chat.message(withId: seed.note)?.sender == nil,
          "\(label): Claw's replies have no forwarded sender")
    check(chat.message(withId: seed.thanks)?.sender?.agentId == "kiko", "\(label): Kiko's thanks is Kiko's")

    // The transcript the chat view renders: a new group at each change of speaker.
    func holds(_ entry: TranscriptEntry, _ id: String) -> Bool {
        switch entry {
        case let .assistant(turn): turn.id == id || turn.textIds.contains(id)
        case let .user(item): item.transcriptId == id
        case .marker: false
        }
    }
    let entries = chat.entries
    guard let start = entries.firstIndex(where: { holds($0, seed.intro) }), start + 4 < entries.count else {
        check(false, "\(label): Kiko's intro is in the transcript (\(entries.count) entries)")
        return
    }
    let run = Array(entries[start...(start + 4)])
    let ids = [seed.intro, seed.reply, seed.thanks, seed.note, seed.you]
    check(zip(run, ids).allSatisfy { holds($0, $1) }, "\(label): each message is its own group, in order")
    let senders: [String?] = run.map { entry in
        switch entry {
        case let .assistant(turn): turn.sender?.displayName(agents: agents) ?? claw
        case .user: "You"
        case .marker: nil
        }
    }
    check(senders == ["Kiko", claw, "Kiko", claw, "You"], "\(label): groups alternate Kiko / \(claw) / Kiko / \(claw) / you (\(senders))")
    if case let .assistant(kiko) = run[0] {
        check(kiko.body == intro?.plainText, "\(label): Kiko's group holds only her message")
        check(kiko.sender?.marker(agents: agents, receivingAgentId: "main") == "from Kiko’s chat" && kiko.sender?.canOpenSource == true,
              "\(label): “from Kiko’s chat” marker opens her chat")
        check(kiko.model == nil, "\(label): Kiko's message isn't credited to \(claw)'s model (\(kiko.model ?? "nil"))")
    }
    check(gateway.sessions.contains { $0.key == "agent:kiko:main" }, "\(label): Kiko's source chat exists")

    // Reply chips and quote cards name the actual sender.
    check(chat.replyTarget(for: seed.intro, you: "You", agent: claw)?.senderLabel == "Kiko", "\(label): replying to Kiko names Kiko")
    check(chat.replyTarget(for: seed.reply, you: "You", agent: claw)?.senderLabel == claw, "\(label): replying to \(claw) names \(claw)")
    let replyJSON = #"{"role":"user","content":"Can you share that budget?","__openclaw":{"id":"quote-check","replyToId":"\#(seed.intro)"}}"#
    if let reply = ChatItem(json(replyJSON), fallbackIndex: 0), let quote = chat.quote(for: reply) {
        check(quote.sender == .label("Kiko") && quote.text?.hasPrefix("Hi Claw!") == true,
              "\(label): quote card of a reply to Kiko names Kiko (\(String(describing: quote.sender)))")
    } else {
        check(false, "\(label): quote card of a reply to Kiko")
    }
}

/// Search results name Kiko for her message, not the chat's agent.
@MainActor
private func checkForwardedSearch(_ gateway: GatewayStore, label: String) async {
    let results = await waitForSearch(gateway, "finance assistant", timeout: 20) { results in
        results.chats.contains { $0.sessionKey == "agent:main:main" }
    }
    let hit = results?.chats.first { $0.sessionKey == "agent:main:main" }?.messages.first
    check(hit?.sender == "Kiko", "\(label): search result for Kiko's message names Kiko (\(hit?.sender ?? "no hit"))")
}

@MainActor
private func connectForwarded(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor(label, timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(label) connected")
    if !connected { gateway.stop() }
    return connected ? gateway : nil
}

/// The demo: Kiko introduced herself to Claw in Claw's main chat.
@MainActor
func runDemoForwarded() async {
    guard let gateway = await connectForwarded(.demo(), "demo for forwarded messages") else { return }
    defer { gateway.stop() }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let loaded = await waitFor("demo main history with Kiko") { chat.message(withId: "demo-kiko-intro") != nil }
    check(loaded, "demo main history has Kiko's intro")
    guard loaded else { return }
    checkForwardedExchange(gateway, chat, ForwardedSeed(intro: "demo-kiko-intro", reply: "demo-claw-to-kiko", thanks: "demo-kiko-thanks",
                                                        note: "demo-claw-kiko-note", you: "demo-main-thanks-both"), label: "demo")
    await checkForwardedSearch(gateway, label: "demo")

    // Kiko's own chat shows the sessions_send calls, as her messages.
    let kiko = gateway.chat(for: "agent:kiko:main")
    await kiko.load()
    _ = await waitFor("Kiko's chat") { kiko.message(withId: "demo-kiko-summary") != nil }
    check(kiko.items.allSatisfy { $0.sender == nil }, "Kiko's own chat has no forwarded senders")
}

/// The mock: the same exchange and a Morning briefing cron prompt, from `chat.history`.
@MainActor
func runLiveForwarded(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock forwarded", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await connectForwarded(profile, "mock for forwarded messages") else { return }
    defer { gateway.stop() }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let loaded = await waitFor("mock main history with Kiko") { chat.message(withId: "seed-kiko-intro") != nil }
    if !loaded {
        _ = await chat.locate("seed-kiko-intro")
    }
    check(chat.message(withId: "seed-kiko-intro") != nil, "mock main history has Kiko's intro")
    guard chat.message(withId: "seed-kiko-intro") != nil else { return }
    checkForwardedExchange(gateway, chat, ForwardedSeed(intro: "seed-kiko-intro", reply: "seed-claw-to-kiko", thanks: "seed-kiko-thanks",
                                                        note: "seed-claw-kiko-note", you: "seed-thanks-both"), label: "mock")

    let briefing = chat.message(withId: "seed-briefing-prompt")
    check(briefing?.sender?.kind == .automation && briefing?.sender?.displayName(agents: gateway.agents) == "Morning briefing",
          "mock: cron prompt is from the Morning briefing automation (\(String(describing: briefing?.sender)))")
    check(briefing?.sender?.canOpenSource == false && briefing?.plainText.hasPrefix("Write my morning briefing") == true,
          "mock: cron run isn't offered as a chat, and its prefix is gone")
    check(chat.replyTarget(for: "seed-briefing-prompt", you: "You", agent: "Claw")?.senderLabel == "Morning briefing",
          "mock: replying to the briefing names the automation")
}
