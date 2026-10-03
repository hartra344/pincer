import Foundation
@testable import PincerKit

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
private func checkForwardedExchange(_ gateway: GatewayStore, _ chat: ChatStore, _ seed: ForwardedSeed, label: String) async {
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
        check(kiko.sender?.accessibilityAuthor(agents: agents, receivingAgentId: "main") == "Kiko, forwarded",
              "\(label): VoiceOver names the actual forwarded sender once")
        check(kiko.model == nil, "\(label): Kiko's message isn't credited to \(claw)'s model (\(kiko.model ?? "nil"))")
    }
    check(gateway.sessions.contains { $0.key == "agent:kiko:main" }, "\(label): Kiko's source chat exists")

    // Reply chips and quote cards name the actual sender.
    check(chat.replyTarget(for: seed.intro, you: "You", agent: claw)?.senderLabel == "Kiko", "\(label): replying to Kiko names Kiko")
    check(chat.replyTarget(for: seed.reply, you: "You", agent: claw)?.senderLabel == claw, "\(label): replying to \(claw) names \(claw)")
    let replyJSON = #"{"role":"user","content":"Can you share that budget?","__openclaw":{"id":"quote-check","replyToId":"\#(seed.intro)"}}"#
    if let reply = ChatItem(json(replyJSON), fallbackIndex: 0) {
        // The real cold quote request admits preparation. Await that work before inspecting
        // its text; the public quote API preserves sender metadata immediately.
        _ = chat.quote(for: reply)
        await chat.quotePreviewPreparation.drain()
        guard let quote = chat.quote(for: reply) else {
            check(false, "\(label): quote card of a reply to Kiko")
            return
        }
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

/// Your unsent (failed or queued) messages between Kiko's and Claw's are their own rows and
/// never join or split the agents' groups.
@MainActor
private func checkForwardedWithOutbox(_ gateway: GatewayStore, _ chat: ChatStore) async {
    let failedId = "forwarded-outbox-failed"
    gateway.injectOutboxEntry(OutboxEntry(
        id: failedId, sessionKey: "agent:main:main", agentId: "main", text: "Kiko, can you add the NAS drives too?",
        createdAt: Date(), state: .failed(OutboxFailure(message: "The Gateway timed out.", retryable: true)), attempts: 1))
    defer { gateway.discardOutbox() }
    let shown = await waitFor("failed row in Claw's chat") { chat.items.contains { $0.idempotencyKey == failedId && $0.outboxState != nil } }
    check(shown, "demo: a failed message shows in Claw's chat with Kiko's messages")
    guard shown, let failed = chat.items.first(where: { $0.idempotencyKey == failedId }),
          let intro = chat.message(withId: "demo-kiko-intro"), let reply = chat.message(withId: "demo-claw-to-kiko"),
          let thanks = chat.message(withId: "demo-kiko-thanks"), let note = chat.message(withId: "demo-claw-kiko-note")
    else { return }
    if case let .user(last)? = chat.entries.last {
        check(last.idempotencyKey == failedId && last.sender == nil, "demo: the failed row is its own row, from you")
    } else {
        check(false, "demo: the failed row ends the transcript (\(String(describing: chat.entries.last?.id)))")
    }
    check(chat.message(withId: "demo-kiko-intro")?.sender?.agentId == "kiko", "demo: Kiko's attribution survives an outbox change")

    // Interleaved: Kiko, you (failed), Claw, Kiko, you (queued), Claw.
    var queued = failed
    queued.id = "outbox:forwarded-outbox-queued"
    queued.idempotencyKey = "forwarded-outbox-queued"
    queued.outboxState = .queued
    let entries = TranscriptBuilder.build([intro, failed, reply, thanks, queued, note])
    let shape: [String] = entries.map { entry in
        switch entry {
        case let .assistant(turn): turn.sender?.displayName(agents: gateway.agents) ?? "Claw"
        case let .user(item): item.outboxState == .queued ? "queued" : (item.outboxState == nil ? "you" : "failed")
        case .marker: "-"
        }
    }
    check(shape == ["Kiko", "failed", "Claw", "Kiko", "queued", "Claw"],
          "demo: unsent rows between forwarded messages keep every group apart (\(shape))")
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
    await checkForwardedExchange(gateway, chat, ForwardedSeed(intro: "demo-kiko-intro", reply: "demo-claw-to-kiko", thanks: "demo-kiko-thanks",
                                                        note: "demo-claw-kiko-note", you: "demo-main-thanks-both"), label: "demo")
    await checkForwardedSearch(gateway, label: "demo")
    await checkForwardedWithOutbox(gateway, chat)

    // Kiko's own chat shows the sessions_send calls, as her messages.
    let kiko = gateway.chat(for: "agent:kiko:main")
    await kiko.load()
    _ = await waitFor("Kiko's chat") { kiko.message(withId: "demo-kiko-summary") != nil }
    check(kiko.items.allSatisfy { $0.sender == nil }, "Kiko's own chat has no forwarded senders")
    await runDemoForwardedSenderRefresh()
}

/// A stale segmented v9 cache keeps Kiko's already-projected rows visible, then repairs those
/// same stable ids by scanning the demo Gateway's older pages through the production headless fill.
@MainActor
private func runDemoForwardedSenderRefresh() async {
    check(ChatStore.forwardedRefreshPageDisposition(messageCount: 0, reportedHasMore: true,
                                                     requestedOffset: 120, returnedOffset: 120,
                                                     fallbackLimit: 120) == .abort,
          "sender refresh keeps its marker when an empty page claims more history")
    check(ChatStore.forwardedRefreshPageDisposition(messageCount: 0, reportedHasMore: nil,
                                                     requestedOffset: 120, returnedOffset: nil,
                                                     fallbackLimit: 120) == .complete(nextOffset: 120),
          "sender refresh accepts a normal empty terminal page")
    let profile = GatewayProfile.demoForwardedSenderRefresh()
    let (defaults, suite) = scratchDefaults()
    // Bootstrap may open its selected chat even while background prefetch is paused. Keep this
    // chat unopened until its pre-upgrade cache is seeded, as on the first launch after upgrade.
    defaults.set("agent:kiko:main", forKey: "pincer.selected.\(profile.id.uuidString)")
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    let root = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-forwarded-refresh-\(UUID().uuidString)",
                                                                 directoryHint: .isDirectory)
    gateway.cacheRoot = root
    gateway.appIsActive = false
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("long-history demo for forwarded cache repair", timeout: 25) {
        gateway.state.isConnected && gateway.sessions["agent:main:main"] != nil
    }
    check(connected, "forwarded cache repair demo connected")
    defer {
        gateway.stop()
        TranscriptCache.removeAll(gatewayId: gateway.id, root: root)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
    guard connected else { return }

    let key = "agent:main:main"
    let response: JSONValue
    do {
        response = try await gateway.connection.request("chat.history", .object([
            "sessionKey": .string(key), "limit": .number(300),
        ]), timeout: 10)
    } catch {
        check(false, "forwarded cache repair reads the demo history: \(error.localizedDescription)")
        return
    }
    let raw = response["messages"]?.array ?? []
    let newest: JSONValue
    do {
        newest = try await gateway.connection.request("chat.history", .object([
            "sessionKey": .string(key), "limit": .number(120),
        ]), timeout: 10)
    } catch {
        check(false, "forwarded cache repair reads the newest demo page: \(error.localizedDescription)")
        return
    }
    let newestIds = Set((newest["messages"]?.array ?? []).compactMap { $0["__openclaw"]?["id"]?.text })
    check(raw.count > 120 && !newestIds.contains(DemoGateway.kikoIntroId),
          "Kiko's seeded message falls outside the newest 120-item page")

    var staleItems = ChatStore.parse(raw, fallbackBase: 0)
    for index in staleItems.indices where staleItems[index].sender != nil { staleItems[index].sender = nil }
    var offlineOnly = ChatItem(id: "offline-only-forwarded-refresh", role: .user,
                               blocks: [.text("An offline-only cached note")], timestamp: Date(timeIntervalSince1970: 1))
    offlineOnly.transcriptId = "offline-only-forwarded-refresh"
    staleItems.insert(offlineOnly, at: 0)
    await TranscriptCache.save(TranscriptCache.Snapshot(version: 9, items: staleItems, complete: true,
                                                          activityMs: gateway.sessions[key]?.activityMs),
                               gatewayId: gateway.id, sessionKey: key, root: root)
    await TranscriptCache.flush(gatewayId: gateway.id, root: root)

    // Remove the v10-only field to reproduce a real pre-v10 manifest instead of a handcrafted RPC shape.
    if let manifestURL = TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: root),
       let bytes = try? Data(contentsOf: manifestURL),
       var manifest = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    {
        manifest["version"] = 9
        manifest.removeValue(forKey: "forwardedSenderRefreshPending")
        if let oldManifest = try? JSONSerialization.data(withJSONObject: manifest) {
            try? oldManifest.write(to: manifestURL, options: .atomic)
        }
        var oldMeta: [String: Any] = ["version": 9, "complete": true, "retained": false]
        if let activity = gateway.sessions[key]?.activityMs { oldMeta["activityMs"] = activity }
        if let oldSidecar = try? JSONSerialization.data(withJSONObject: oldMeta) {
            try? oldSidecar.write(to: manifestURL.appendingPathExtension("meta"), options: .atomic)
        }
    }

    let chat = gateway.chat(for: key)
    chat.windowLimit = min(staleItems.count, TranscriptCache.maxItems)
    await chat.restoreFromCache()
    let cachedIntro = chat.message(withId: DemoGateway.kikoIntroId)
    check(cachedIntro != nil && cachedIntro?.sender == nil,
          "offline cached Kiko message stays visible before the Gateway refresh")
    check(chat.message(withId: offlineOnly.id)?.plainText == "An offline-only cached note",
          "offline-only cache rows stay available before refresh")

#if DEBUG
    let refreshWasPending = chat.forwardedSenderRefreshPending
    ForwardedSenderRefreshDiagnostics.reset(gatewayID: gateway.id, sessionKey: key)
#endif
    gateway.appIsActive = true
    await chat.load()
    await gateway.startHeadlessFill(sessionKey: key, agentId: "main").value
#if DEBUG
    let refreshEvents = ForwardedSenderRefreshDiagnostics.events(gatewayID: gateway.id, sessionKey: key)
    let refreshOrdinals = refreshEvents.map(\.ordinal)
    check((!refreshWasPending || !refreshEvents.isEmpty) && refreshEvents.count <= 40,
          "a pending demo sender refresh records a bounded phase trace, including typed early aborts")
    check(zip(refreshOrdinals, refreshOrdinals.dropFirst()).allSatisfy { $0.0 < $0.1 },
          "demo sender refresh phase trace preserves event order")
#endif
    await TranscriptCache.flush(gatewayId: gateway.id, root: root)
    let repaired = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key, root: root)
    let repairedIntro = repaired?.items.first { $0.transcriptId == DemoGateway.kikoIntroId }
    let repairedThanks = repaired?.items.first { $0.transcriptId == DemoGateway.kikoThanksId }
    let ids = repaired?.items.compactMap(\.transcriptId) ?? []
    let persistedRepairPassed = repaired?.forwardedSenderRefreshPending == false
        && repairedIntro?.sender?.agentId == "kiko" && repairedThanks?.sender?.agentId == "kiko"
    let openIntro = chat.message(withId: DemoGateway.kikoIntroId)
    let openRepairPassed = openIntro?.sender?.agentId == "kiko"
    if !persistedRepairPassed || !openRepairPassed {
        func itemSummary(_ item: ChatItem?) -> String {
            guard let item else { return "missing" }
            let id = String((item.transcriptId ?? item.id).prefix(64))
            let sender = String((item.sender?.agentId ?? "nil").prefix(40))
            return "\(id):\(sender)"
        }
        let chatState = (items: chat.items.count, pending: chat.forwardedSenderRefreshPending,
                         completed: chat.forwardedSenderRefreshCompleted, loaded: chat.hasLoaded,
                         fills: gateway.headlessFillStarts[key, default: 0])
        let historyRequests = await gateway.connection.demoHistoryRequestCount(for: key)
        let pending = repaired.map { String($0.forwardedSenderRefreshPending) } ?? "missing"
        let offlineOnlyRetained = repaired?.items.contains(where: { $0.id == offlineOnly.id }) ?? false
        let uniqueIds = Set(ids).count
        print("  forwarded refresh diagnostics: persistedPending=\(pending), persistedItems=\(repaired?.items.count ?? 0), retained=\(repaired?.retained ?? false), complete=\(repaired?.complete ?? false), ids=\(ids.count)/\(uniqueIds), offlineOnly=\(offlineOnlyRetained), intro=\(itemSummary(repairedIntro)), thanks=\(itemSummary(repairedThanks)), openIntro=\(itemSummary(openIntro)), chatItems=\(chatState.items), chatPending=\(chatState.pending), chatCompleted=\(chatState.completed), chatLoaded=\(chatState.loaded), headlessFills=\(chatState.fills), historyRequests=\(historyRequests)")
#if DEBUG
        let recentEvents = refreshEvents.suffix(12).map { "\($0.ordinal):\($0.phase)" }.joined(separator: "; ")
        print("  forwarded refresh phases: retained=\(refreshEvents.count)/40, recent=\(recentEvents)")
#endif
    }
    check(persistedRepairPassed,
          "older same-id messages are repaired with Kiko's sender metadata")
    check(openRepairPassed,
          "the open chat adopts repaired sender metadata without requiring a cache clear")
    check(repaired?.items.contains(where: { $0.id == offlineOnly.id }) == true,
          "offline-only cache rows survive the authoritative refresh")
    check(ids.count == Set(ids).count, "the refresh does not duplicate stable transcript ids")
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
    await checkForwardedExchange(gateway, chat, ForwardedSeed(intro: "seed-kiko-intro", reply: "seed-claw-to-kiko", thanks: "seed-kiko-thanks",
                                                        note: "seed-claw-kiko-note", you: "seed-thanks-both"), label: "mock")

    let briefing = chat.message(withId: "seed-briefing-prompt")
    check(briefing?.sender?.kind == .automation && briefing?.sender?.displayName(agents: gateway.agents) == "Morning briefing",
          "mock: cron prompt is from the Morning briefing automation (\(String(describing: briefing?.sender)))")
    check(briefing?.sender?.canOpenSource == false && briefing?.plainText.hasPrefix("Write my morning briefing") == true,
          "mock: cron run isn't offered as a chat, and its prefix is gone")
    check(chat.replyTarget(for: "seed-briefing-prompt", you: "You", agent: "Claw")?.senderLabel == "Morning briefing",
          "mock: replying to the briefing names the automation")
}
