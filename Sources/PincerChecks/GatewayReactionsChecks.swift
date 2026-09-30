import Foundation
@testable import PincerKit

// Gateway-level reactions (#120, #108): session.reactions.set/list and the session.reaction event.
// Live against the mock (methods on), and against the mock with MOCK_NO_REACTIONS=1 (an older Gateway).

@MainActor
private func connect(_ name: String, url: String, token: String) async -> GatewayStore? {
    let profile = GatewayProfile(name: name, url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor(name, timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(name) connected")
    return connected ? gateway : nil
}

@MainActor
private func forget(_ store: GatewayStore) {
    for prefix in ["reactions", "reactionsSynced"] {
        UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(store.id.uuidString)")
    }
}

@MainActor
private func messageId(_ chat: ChatStore, _ role: ChatRole, containing text: String) -> String? {
    chat.items.first { $0.role == role && $0.plainText.contains(text) }?.transcriptId
}

@MainActor
func checkGatewayReactions() {
    let sam = ReactionIdentity(id: "sam", label: "Sam")
    let list = [ReactionSummary(emoji: "👍", identities: [ReactionIdentity(id: "me", label: "Me"), sam]),
                ReactionSummary(emoji: "🎉", identities: [sam, ReactionIdentity(id: "riley")])]
    let groups = Reactions.groups(agent: ["👍"], agentName: "Claw", shared: list, selfId: "me")
    check(groups == [ReactionGroup(emoji: "👍", actors: [.agent("Claw"), .you, .person("Sam")]),
                     ReactionGroup(emoji: "🎉", actors: [.person("Sam"), .person("Someone")])],
          "groups merge the agent's inferred reaction with shared ones; mine → you, no label → Someone (\(groups))")
    check(Reactions.mine(in: list, selfId: "me") == ["👍"] && Reactions.mine(in: list, selfId: nil).isEmpty, "mine matches the own profile id only")
    let added = Reactions.applying("🎉", remove: false, to: list, selfId: "me")
    check(Reactions.mine(in: added, selfId: "me") == ["👍", "🎉"] && Reactions.applying("🎉", remove: true, to: added, selfId: "me") == list,
          "applying add then remove round-trips")
    let parsed = json(#"[{"emoji":"👍","count":1,"identities":[{"id":"me","label":"Me"}]},{"emoji":""}]"#)
    check(ReactionSummary.parse(parsed) == [ReactionSummary(emoji: "👍", identities: [ReactionIdentity(id: "me", label: "Me")])],
          "summaries parse; ones without an emoji are dropped")
    check(Reactions.isGatewayReactionsUnavailable(GatewayError.rpc(code: "INVALID_REQUEST", message: "identified reaction author required", details: nil))
          && Reactions.isGatewayReactionsUnavailable(GatewayError.rpc(code: "FORBIDDEN", message: "no", details: nil))
          && !Reactions.isGatewayReactionsUnavailable(GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown message", details: nil)),
          "fallback errors: no identified author / forbidden / unknown method, but not an unknown message")

    // Events replace a message wholesale; ones during an in-flight list win over its snapshot.
    let gateway = GatewayStore(profile: .demo(), defaults: UserDefaults(suiteName: "pincer-checks-\(UUID())")!, identity: DeviceIdentity.loadOrCreate())
    let chat = gateway.chat(for: "agent:main:main")
    func event(_ id: String, _ reactions: String) -> JSONValue {
        json(#"{"sessionKey":"agent:main:main","messageId":"\#(id)","emoji":"👍","action":"added","reactions":\#(reactions)}"#)
    }
    let one = #"[{"emoji":"👍","identities":[{"id":"sam","label":"Sam"}]}]"#
    chat.reactionSync.isListing = true
    chat.handleReactionEvent(event("m1", one))
    check(chat.sharedReactions["m1"]?.count == 1 && chat.reactionSync.eventUpdates["m1"]?.count == 1, "an event during the list is applied and remembered")
    chat.reactionSync.isListing = false
    chat.handleReactionEvent(event("m1", #"[{"emoji":"🎉","identities":[{"id":"riley"}]}]"#))
    check(chat.sharedReactions["m1"]?.map(\.emoji) == ["🎉"], "an event replaces the message's reactions")
    chat.handleReactionEvent(event("m1", "[]"))
    check(chat.sharedReactions["m1"] == nil, "an empty aggregate clears it")
}

/// Live against a mock with session.reactions.* (the default): list, set, the event, fallback-free, migration.
@MainActor
func runLiveGatewayReactions(url: String, token: String) async {
    guard let gateway = await connect("Mock gateway reactions", url: url, token: token),
          let other = await connect("Mock gateway reactions 2", url: url, token: token) else { return }
    defer {
        gateway.stop()
        other.stop()
        forget(gateway)
        forget(other)
    }
    let main = "agent:main:main"
    let lab = "agent:main:discord:channel:123"
    let agentName = gateway.agents.first { $0.id == "main" }?.name ?? "Claw"
    check(gateway.supportsSessionReactions && !gateway.sessionReactionsOff, "the mock advertises session.reactions.set and .list")

    let chat = gateway.chat(for: main)
    await chat.load()
    let synced = await waitFor("reactions listed") { chat.usesGatewayReactions && !chat.sharedReactions.isEmpty }
    check(synced && chat.reactionSelfId == "demo-owner", "list on open; own identity comes from users.self (\(chat.reactionSelfId ?? "nil"))")
    guard synced, let assistantId = messageId(chat, .assistant, containing: "Disk status"),
          let questionId = messageId(chat, .user, containing: "disk usage")
    else {
        check(false, "the seeded messages")
        return
    }
    func groups(_ store: ChatStore, _ id: String) -> [ReactionGroup] { store.reactionGroups(for: id, agentName: agentName) }
    check(groups(chat, assistantId) == [ReactionGroup(emoji: "👍", actors: [.you, .person("Sam")]),
                                         ReactionGroup(emoji: "🎉", actors: [.person("Sam"), .person("Riley")])],
          "seeded: your 👍 shows as you, others by name (\(groups(chat, assistantId)))")
    check(groups(chat, questionId).contains(ReactionGroup(emoji: "🙏", actors: [.person("Sam")])), "another person's reaction on a user message")

    let device2 = other.chat(for: main)
    await device2.load()
    _ = await waitFor("second device listed") { device2.usesGatewayReactions && !device2.sharedReactions.isEmpty }

    // Toggle: optimistic, reconciled, and the other device gets the event.
    chat.toggleReaction("🎉", on: assistantId)
    check(groups(chat, assistantId).contains { $0.emoji == "🎉" && $0.actors.contains(.you) }, "toggling on is optimistic")
    let addedEverywhere = await waitFor("event to device 2") { groups(device2, assistantId).contains { $0.emoji == "🎉" && $0.actors.contains(.you) } }
    check(addedEverywhere && groups(chat, assistantId).first { $0.emoji == "🎉" }?.actors == [.person("Sam"), .person("Riley"), .you],
          "the other device sees it through session.reaction; the reply keeps the order (\(groups(chat, assistantId)))")
    check(chat.notice == nil && chat.usesGatewayReactions && !gateway.sessionReactionsOff, "no notice, no fallback")
    chat.toggleReaction("🎉", on: assistantId)
    check(!groups(chat, assistantId).contains { $0.emoji == "🎉" && $0.actors.contains(.you) }, "toggling off is optimistic")
    let removedEverywhere = await waitFor("removal event to device 2") { !groups(device2, assistantId).contains { $0.emoji == "🎉" && $0.actors.contains(.you) } }
    check(removedEverywhere && groups(device2, assistantId).first { $0.emoji == "🎉" }?.actors == [.person("Sam"), .person("Riley")],
          "removal reaches the other device; other people's reactions stay")
    chat.toggleReaction("👍", on: assistantId)
    check(groups(chat, assistantId).first { $0.emoji == "👍" }?.actors == [.person("Sam")], "removing your seeded 👍 leaves Sam's")
    _ = await waitFor("👍 removal event") { groups(device2, assistantId).first { $0.emoji == "👍" }?.actors == [.person("Sam")] }
    chat.toggleReaction("👍", on: assistantId)
    let restored = await waitFor("👍 back") { groups(device2, assistantId).first { $0.emoji == "👍" }?.actors.contains(.you) == true }
    check(restored, "adding it back")

    // Bridged Discord message: the Gateway mirrors, so Pincer sends no message.action and shows no notice.
    let labChat = gateway.chat(for: lab)
    await labChat.load()
    _ = await waitFor("lab listed") { labChat.usesGatewayReactions }
    guard let sensorId = labChat.items.first(where: { $0.channelMessageId == "1300000000000000001" })?.transcriptId else {
        check(false, "discord user message with its channel id")
        return
    }
    check(groups(labChat, sensorId) == [ReactionGroup(emoji: "👀", actors: [.agent(agentName), .person("Riley")])]
          || groups(labChat, sensorId).contains(ReactionGroup(emoji: "👀", actors: [.person("Riley")])),
          "shared 👀 from Riley merges with the agent's (\(groups(labChat, sensorId)))")
    labChat.toggleReaction("🚀", on: sensorId)
    let mirrored = await waitFor("lab reaction") { labChat.sharedReactions[sensorId]?.contains { $0.emoji == "🚀" && $0.identities.contains { $0.id == "demo-owner" } } == true }
    try? await Task.sleep(for: .milliseconds(800)) // Wait out any (unexpected) forwarded action's notice.
    check(mirrored && labChat.notice == nil && gateway.reactionForwardingOff.isEmpty && gateway.reactionNoticeShown.isEmpty,
          "reacting on a bridged message goes through session.reactions.set only (\(labChat.notice ?? "no notice"))")
    check(gateway.myReactions(sessionKey: lab, messageId: sensorId).isEmpty, "nothing is written to users.prefs")
    labChat.toggleReaction("🚀", on: sensorId)
    _ = await waitFor("lab removal") { labChat.sharedReactions[sensorId]?.contains { $0.emoji == "🚀" } != true }

    // Migration: pincer.reactions entries move over once, then are deleted (also for unknown messages).
    let prefKey = Reactions.prefKey
    let entryKey = Reactions.prefEntryKey(sessionKey: main, messageId: questionId)
    let ghostKey = Reactions.prefEntryKey(sessionKey: main, messageId: "ghost-message")
    let written = try? await gateway.connection.request(
        "users.prefs.set", .object(["entries": .object([prefKey: .object([entryKey: .string("🔥"), ghostKey: .string("🎉")])])]), timeout: 15)
    check(written?["status"]?.string == "ok", "seeded legacy pincer.reactions entries")
    guard let fresh = await connect("Mock gateway reactions migrate", url: url, token: token) else { return }
    defer {
        fresh.stop()
        forget(fresh)
    }
    let migrating = fresh.chat(for: main)
    await migrating.load()
    let migrated = await waitFor("migration", timeout: 20) {
        Reactions.mine(in: migrating.sharedReactions[questionId] ?? [], selfId: "demo-owner").contains("🔥")
            && fresh.reactions[entryKey] == nil && fresh.reactions[ghostKey] == nil
    }
    check(migrated, "legacy reaction pushed via set, and both pref entries deleted (\(fresh.reactions))")
    check(migrating.sharedReactions["ghost-message"] == nil, "an unknown message's reaction isn't invented")
    check(migrating.reactionSync.migratedEpoch == fresh.connectionEpoch, "migration ran for this connection")
    let seen = await waitFor("migrated reaction on the first device") { chat.sharedReactions[questionId]?.contains { $0.emoji == "🔥" } == true }
    check(seen, "the first device sees the migrated reaction via the event")
    migrating.toggleReaction("🔥", on: questionId)
    _ = await waitFor("cleanup") { migrating.sharedReactions[questionId]?.contains { $0.emoji == "🔥" } != true }
}

/// Against a Gateway without session.reactions.* (mock with MOCK_NO_REACTIONS=1): reactions stay on users.prefs.
@MainActor
func runLiveNoSessionReactions(url: String, token: String) async {
    guard let gateway = await connect("Mock without gateway reactions", url: url, token: token),
          let other = await connect("Mock without gateway reactions 2", url: url, token: token) else { return }
    defer {
        gateway.stop()
        other.stop()
        forget(gateway)
        forget(other)
    }
    let main = "agent:main:main"
    let lab = "agent:main:discord:channel:123"
    check(!gateway.supportsSessionReactions && gateway.supportsMessageAction, "methods hidden; message.action still there")
    let chat = gateway.chat(for: main)
    await chat.load()
    _ = await waitFor("main history") { chat.items.contains { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty } }
    try? await Task.sleep(for: .milliseconds(500)) // A (wrongly) started list would have landed by now.
    check(!chat.usesGatewayReactions && chat.sharedReactions.isEmpty && chat.reactionSelfId == nil, "no gateway reactions listed")
    let labChat = gateway.chat(for: lab)
    await labChat.load()
    guard let sensorId = labChat.items.first(where: { $0.channelMessageId == "1300000000000000001" })?.transcriptId,
          let targetId = chat.items.last(where: { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty })?.transcriptId
    else {
        check(false, "messages to react to")
        return
    }

    // pincer.reactions round-trips through users.prefs, and bridged reactions forward.
    labChat.toggleReaction("👍", on: sensorId)
    let synced = await waitFor("reaction sync") { other.myReactions(sessionKey: lab, messageId: sensorId) == ["👍"] }
    check(synced && labChat.reactionGroups(for: sensorId, agentName: "Claw").contains { $0.emoji == "👍" && $0.actors == [.you] },
          "your reaction syncs through users.prefs to another device")
    try? await Task.sleep(for: .seconds(1)) // Wait out a forwarded action's notice.
    check(labChat.notice == nil, "message.action react on the Discord session succeeded (no notice)")
    let otherLab = other.chat(for: lab)
    await otherLab.load()
    otherLab.toggleReaction("👍", on: sensorId)
    let cleared = await waitFor("reaction removal sync") { gateway.myReactions(sessionKey: lab, messageId: sensorId).isEmpty }
    check(cleared && gateway.reactions[Reactions.prefEntryKey(sessionKey: lab, messageId: sensorId)] == nil,
          "removing on the other device deletes the pref key everywhere")
    chat.toggleReaction("🎉", on: targetId)
    let nativeSynced = await waitFor("native reaction sync") { other.myReactions(sessionKey: main, messageId: targetId) == ["🎉"] }
    check(nativeSynced && chat.notice == nil, "native chat reactions are Pincer-only and still sync")
    chat.toggleReaction("🎉", on: targetId)
    _ = await waitFor("native removal") { other.myReactions(sessionKey: main, messageId: targetId).isEmpty }
    check(chat.sharedReactions.isEmpty && labChat.sharedReactions.isEmpty, "the prefs path never fills the shared reactions")
}
