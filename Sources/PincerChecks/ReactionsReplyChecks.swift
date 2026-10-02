import Foundation
@testable import PincerKit

// Replies (#45) and reactions (#74): parsing, derivation, codecs and the send fallback offline,
// then against the built-in demo and the mock Gateway.

private func item(_ text: String) -> ChatItem? {
    ChatItem(json(text), fallbackIndex: 0)
}

private func items(_ texts: [String]) -> [ChatItem] {
    texts.enumerated().compactMap { ChatItem(json($1), fallbackIndex: $0) }
}

/// A user message with an optional channel message id.
private func userJSON(_ id: String, _ text: String = "hi", channelId: String? = nil, runId: String? = nil) -> String {
    let transport = channelId.map { #","transport":{"channel":"discord","messageId":"\#($0)"}"# } ?? ""
    let run = runId.map { #","runId":"\#($0)""# } ?? ""
    return #"{"role":"user","content":[{"type":"text","text":"\#(text)"}],"__openclaw":{"id":"\#(id)"\#(transport)\#(run)}}"#
}

/// An assistant message calling the `message` tool with `arguments`.
private func callJSON(_ id: String, callId: String, name: String = "message", _ arguments: String, runId: String? = nil) -> String {
    let run = runId.map { #","runId":"\#($0)""# } ?? ""
    return #"{"role":"assistant","content":[{"type":"toolCall","id":"\#(callId)","name":"\#(name)","arguments":\#(arguments)}],"__openclaw":{"id":"\#(id)"\#(run)}}"#
}

private func resultJSON(_ id: String, callId: String, isError: Bool) -> String {
    #"{"role":"toolResult","toolCallId":"\#(callId)","toolName":"message","isError":\#(isError),"content":[{"type":"text","text":"{}"}],"__openclaw":{"id":"\#(id)"}}"#
}

private func assistantJSON(_ id: String, _ text: String, runId: String? = nil) -> String {
    let run = runId.map { #","runId":"\#($0)""# } ?? ""
    return #"{"role":"assistant","content":[{"type":"text","text":"\#(text)"}],"__openclaw":{"id":"\#(id)"\#(run)}}"#
}

@MainActor
func checkReactionsReply() {
    // Parsing (AC-1).
    let reply = item(#"""
    {"role":"user","content":[{"type":"text","text":"that one"}],"__openclaw":{"id":"u2","replyToId":"a1",
     "replyToPreview":{"text":"Disk status","senderLabel":"Claw"},
     "transport":{"channel":"discord","messageId":"1300000000000000001","conversationRef":"channel:123"}}}
    """#)
    check(reply?.replyToId == "a1" && reply?.replyToPreview == ReplyPreview(text: "Disk status", senderLabel: "Claw"),
          "replyToId and replyToPreview parse")
    check(reply?.channelMessageId == "1300000000000000001" && reply?.transportChannel == "discord"
          && reply?.conversationRef == "channel:123", "transport messageId, channel and conversationRef parse")
    let plain = item(userJSON("u1"))
    check(plain != nil && plain?.replyToId == nil && plain?.replyToPreview == nil && plain?.channelMessageId == nil
          && plain?.transportChannel == nil && plain?.conversationRef == nil && plain?.plainText == "hi",
          "messages without reply or transport facts parse as before")
    let empty = item(#"""
    {"role":"user","content":[{"type":"text","text":"x"}],"__openclaw":{"id":"u3","replyToId":"",
     "replyToPreview":{"text":"","senderLabel":"Claw"},"transport":{"channel":"","messageId":"  ","conversationRef":""}}}
    """#)
    check(empty?.replyToId == nil && empty?.replyToPreview == nil && empty?.channelMessageId == nil
          && empty?.transportChannel == nil && empty?.conversationRef == nil, "empty reply and transport strings are nil")
    let noSender = item(#"{"role":"user","content":[{"type":"text","text":"x"}],"__openclaw":{"id":"u4","replyToId":"a1","replyToPreview":{"text":"t","senderLabel":""}}}"#)
    check(noSender?.replyToPreview == ReplyPreview(text: "t", senderLabel: nil), "empty senderLabel is nil")

    // Replyable targets (AC-7).
    check(plain?.isReplyable == true && item(assistantJSON("a1", "x"))?.isReplyable == true, "committed user and assistant messages are replyable")
    check(item(#"{"role":"user","content":[{"type":"text","text":"x"}],"__openclaw":{"id":"pending:abc"}}"#)?.isReplyable == false,
          "pending: ids aren't replyable")
    check(item(#"{"role":"user","content":[{"type":"text","text":"x"}]}"#)?.isReplyable == false, "messages without a transcript id aren't replyable")
    check(ChatItem(role: .user, blocks: [.text("x")], isPending: true).isReplyable == false, "optimistic sends aren't replyable")
    check(item(#"{"role":"system","content":[],"__openclaw":{"id":"m1","kind":"compaction"}}"#)?.isReplyable == false, "markers aren't replyable")

    // textIds line up with text (AC-2).
    let turnItems = items([
        userJSON("u1"),
        assistantJSON("a1", "one"),
        callJSON("a2", callId: "c1", name: "exec", #"{"command":"ls"}"#),
        resultJSON("r1", callId: "c1", isError: false),
        #"{"role":"assistant","content":[{"type":"text","text":"no id"}]}"#,
        assistantJSON("a3", "two"),
    ])
    let turns = TranscriptBuilder.build(turnItems).compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { return turn }
        return nil
    }
    check(turns.count == 1 && turns[0].text == ["one", "no id", "two"] && turns[0].textIds == ["a1", nil, "a3"]
          && turns[0].textIds.count == turns[0].text.count, "textIds parallel text; tool-only messages add none (\(turns.first?.textIds ?? []))")

    // Agent reactions from the `message` tool (AC-4).
    let reacted = Reactions.agentReactions(in: items([
        userJSON("u1", channelId: "chan-1"),
        userJSON("u2"),
        callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👍","messageId":"chan-1"}"#),
        callJSON("a2", callId: "k2", #"{"action":"react","emoji":"🎉","messageId":"u2"}"#),
        callJSON("a3", callId: "k3", #"{"action":"react","emoji":"✅"}"#),
        callJSON("a4", callId: "k4", #"{"action":"react","emoji":"🔥","messageId":"unknown"}"#),
        callJSON("a5", callId: "k5", #"{"action":"react","emoji":"🚀","messageId":"u1"}"#),
        userJSON("u3"),
    ]))
    check(reacted["u1"] == ["👍", "🚀"], "messageId → channelMessageId, then → transcriptId (\(reacted["u1"] ?? []))")
    check(reacted["u2"] == ["🎉", "✅", "🔥"], "no or unmatched messageId → latest user message before the call (\(reacted["u2"] ?? []))")
    check(reacted["u3"] == nil, "later user messages don't get earlier reactions")
    let onAssistant = Reactions.agentReactions(in: items([
        userJSON("u1"), assistantJSON("a1", "hi"), callJSON("a2", callId: "k1", #"{"action":"react","emoji":"❤️","messageId":"a1"}"#),
    ]))
    check(onAssistant == ["a1": ["❤️"]], "messageId naming an assistant transcript id")
    let removed = Reactions.agentReactions(in: items([
        userJSON("u1"),
        callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👀"}"#),
        callJSON("a2", callId: "k2", #"{"action":"react","emoji":"✅"}"#),
        callJSON("a3", callId: "k3", #"{"action":"react","emoji":"👀","remove":true}"#),
    ]))
    check(removed == ["u1": ["✅"]], "remove: true drops the earlier agent reaction (\(removed))")
    let removedAll = Reactions.agentReactions(in: items([
        userJSON("u1"),
        callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👀"}"#),
        callJSON("a2", callId: "k2", #"{"action":"react","emoji":"👀","remove":true}"#),
    ]))
    check(removedAll.isEmpty, "removing the only reaction leaves no entry")
    let errored = Reactions.agentReactions(in: items([
        userJSON("u1"),
        callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👍"}"#),
        resultJSON("r1", callId: "k1", isError: true),
        callJSON("a2", callId: "k2", #"{"action":"react","emoji":"🎉"}"#),
        resultJSON("r2", callId: "k2", isError: false),
    ]))
    check(errored == ["u1": ["🎉"]], "errored tool results are ignored (\(errored))")
    let ignored = Reactions.agentReactions(in: items([
        userJSON("u1"),
        callJSON("a1", callId: "k1", #"{"action":"send","message":"hi","emoji":"👍"}"#),
        callJSON("a2", callId: "k2", name: "exec", #"{"action":"react","emoji":"👍"}"#),
        callJSON("a3", callId: "k3", #"{"action":"react","emoji":"  "}"#),
        callJSON("a4", callId: "k4", #"{"action":"react"}"#),
    ]))
    check(ignored.isEmpty, "non-react message calls, other tools and missing emoji are ignored (\(ignored))")
    let noUser = Reactions.agentReactions(in: items([callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👍"}"#)]))
    check(noUser.isEmpty, "no user message before the call → no reaction")
    let pendingUser = Reactions.agentReactions(in: [
        item(userJSON("u1"))!,
        ChatItem(role: .user, blocks: [.text("pending")], isPending: true),
        item(callJSON("a1", callId: "k1", #"{"action":"react","emoji":"👍"}"#))!,
    ])
    check(pendingUser == ["u1": ["👍"]], "pending user messages aren't fallback targets")

    // chat.send params (AC-12).
    let withReply = ChatSendRequest.params(sessionKey: "agent:main:main", agentId: nil, message: "hi", idempotencyKey: "k",
                                           attachments: [], replyToId: "a1")
    let withoutReply = ChatSendRequest.params(sessionKey: "agent:main:main", agentId: nil, message: "hi", idempotencyKey: "k",
                                              attachments: [])
    check(withReply["replyToId"]?.string == "a1" && withReply["message"]?.string == "hi", "chat.send carries replyToId, text unmodified")
    check(!withoutReply.keys.contains("replyToId") && Set(withoutReply.keys) == ["sessionKey", "message", "idempotencyKey"],
          "chat.send omits replyToId without a target")

    // Blockquote fallback (AC-15).
    check(Replies.quotedFallback(sender: "Claw", preview: "Line one\nline   two", text: "My answer")
          == "> **Claw:** Line one\n> line two\n\nMy answer", "fallback quotes each line, sender first, blank line, text")
    check(Replies.quotedFallback(sender: "", preview: "just this", text: "ok") == "> just this\n\nok", "fallback without a sender")
    let long = String(repeating: "a", count: 300)
    check(Replies.quotedFallback(sender: "Claw", preview: long, text: "ok")
          == "> **Claw:** \(String(repeating: "a", count: 280))…\n\nok", "fallback truncates at 280 characters + …")
    let twoLong = String(repeating: "b", count: 200) + "\n" + String(repeating: "c", count: 200)
    check(Replies.quotedFallback(sender: "You", preview: twoLong, text: "t")
          == "> **You:** \(String(repeating: "b", count: 200))\n> \(String(repeating: "c", count: 80))…\n\nt",
          "fallback truncation counts over all lines")
    check(Replies.quotedFallback(sender: "Claw", preview: String(repeating: "d", count: 280), text: "t")
          == "> **Claw:** \(String(repeating: "d", count: 280))\n\nt", "exactly 280 characters isn't truncated")
    check(Replies.quotedFallback(sender: "Claw", preview: "# Title\n\n```swift\nlet x = 1\n```\n> quoted", text: "t")
          == "> **Claw:** Title\n> let x = 1\n> quoted\n\nt", "headings, fences, quote markers and blank lines don't break the quote")
    check(Replies.isReplyToRejection(GatewayError.rpc(
        code: "INVALID_REQUEST", message: "invalid chat.send params: at root: unexpected property 'replyToId'", details: nil)),
          "upstream's replyToId rejection is recognised")
    check(!Replies.isReplyToRejection(GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session", details: nil))
          && !Replies.isReplyToRejection(GatewayError.rpc(code: "UNAVAILABLE", message: "replyToId", details: nil))
          && !Replies.isReplyToRejection(GatewayError.timeout("chat.send")), "other send failures aren't a replyToId rejection")

    // Pref codec (AC-29).
    check(Reactions.prefKey == "pincer.reactions"
          && Reactions.prefEntryKey(sessionKey: "agent:main:main", messageId: "0f3c") == "agent:main:main|0f3c", "pref key format")
    check(Reactions.decode("👍 🎉") == ["👍", "🎉"] && Reactions.decode(nil).isEmpty && Reactions.decode("").isEmpty
          && Reactions.decode("👍  👍 🎉") == ["👍", "🎉"], "pref values decode in order, deduped")
    check(Reactions.encode(["👍", "🎉"]) == "👍 🎉" && Reactions.encode([]) == nil, "pref values encode space-joined; empty deletes the key")
    check(Reactions.toggling("🎉", in: ["👍"]) == ["👍", "🎉"] && Reactions.toggling("👍", in: ["👍", "🎉"]) == ["🎉"]
          && Reactions.encode(Reactions.toggling("👍", in: ["👍"])) == nil, "toggle appends in order added, removes, last removal deletes")
    check(Reactions.decode(Reactions.encode(["❤️", "🛠️", "⭐️"])) == ["❤️", "🛠️", "⭐️"], "multi-scalar emoji round-trip")

    // Recent emoji and the quick bar (AC-26, AC-28).
    check(Reactions.recentDefaultsKey == "pincer.recentReactions" && Reactions.quickDefaults == ["👍", "❤️", "😂", "🎉", "👀", "✅"],
          "recent key and quick defaults")
    check(Reactions.recording("👍", in: ["🎉", "👍", "🔥"]) == ["👍", "🎉", "🔥"], "recent is MRU, deduped")
    let full = ["1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣"]
    check(Reactions.recording("🔥", in: full) == ["🔥"] + full.prefix(7), "recent caps at 8")
    check(Reactions.quickBar(recent: []) == Reactions.quickDefaults, "no recent → defaults")
    check(Reactions.quickBar(recent: ["🔥"]) == ["🔥", "👍", "❤️", "😂", "🎉", "👀"], "recent first, padded with defaults to 6")
    check(Reactions.quickBar(recent: ["🎉", "🔥"]) == ["🎉", "🔥", "👍", "❤️", "😂", "👀"], "padding skips emoji already in the bar")
    check(Reactions.quickBar(recent: full) == Array(full.prefix(6)), "quick bar shows 6 of the recent")
    check(Reactions.catalog.count >= 36 && Set(Reactions.catalog).count == Reactions.catalog.count
          && Set(Reactions.quickDefaults).isSubset(of: Reactions.catalog), "picker grid: ~40 unique emoji including the defaults")

    // Groups (AC-5, AC-22).
    let groups = Reactions.groups(agent: ["👍", "✅"], agentName: "Claw", mine: ["🎉", "👍"])
    check(groups.map(\.emoji) == ["👍", "✅", "🎉"] && groups[0].actors == [.agent("Claw"), .you]
          && groups[0].count == 2 && groups[0].includesYou && !groups[1].includesYou, "agent reactions first, then yours, one group per emoji")
    check(groups[0].reactorsText == "You and Claw" && groups[1].reactorsText == "Claw" && groups[2].reactorsText == "You",
          "who reacted (\(groups[0].reactorsText))")
    check(groups[0].accessibilityLabel == "👍, 2 reactions, you and Claw" && groups[1].accessibilityLabel == "✅, 1 reaction, Claw",
          "VoiceOver label (\(groups[0].accessibilityLabel))")
    check(Reactions.groups(agent: ["👍", "👍"], agentName: "Claw", mine: ["👍"]).first?.actors == [.agent("Claw"), .you],
          "an actor counts once per emoji")

    // message.action params (AC-30).
    let add = Reactions.messageActionParams(channel: "discord", sessionKey: "agent:main:discord:channel:123",
                                            channelMessageId: "1300", emoji: "👍", remove: false,
                                            conversationRef: "channel:123", idempotencyKey: "idem")
    check(add["channel"]?.string == "discord" && add["action"]?.string == "react" && add["sessionKey"]?.string == "agent:main:discord:channel:123"
          && add["idempotencyKey"]?.string == "idem" && Set(add.keys) == ["channel", "action", "sessionKey", "params", "idempotencyKey"],
          "message.action top-level shape")
    check(add["params"] == ["messageId": "1300", "emoji": "👍", "to": "channel:123"], "react params: messageId, emoji, to")
    let remove = Reactions.messageActionParams(channel: "discord", sessionKey: "k", channelMessageId: "1300", emoji: "👍",
                                               remove: true, conversationRef: nil, idempotencyKey: "idem2")
    check(remove["params"] == ["messageId": "1300", "emoji": "👍", "remove": true], "remove: true, no `to` without a conversation")

    // ACK 👀 (AC-24).
    let ackItems = items([
        userJSON("u1", runId: "r0"), assistantJSON("a1", "done", runId: "r0"), userJSON("u2", runId: "r1"),
    ])
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: [:]) == "u2", "👀 on your latest message while running")
    check(Reactions.ackTarget(items: ackItems, isRunning: false, runId: nil, agentReactions: [:]) == nil, "no 👀 when idle")
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: ["u2": ["👀"]]) == nil,
          "no 👀 when the agent already reacted 👀")
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: ["u2": ["✅"]]) == "u2",
          "other agent reactions keep the 👀")
    check(Reactions.ackTarget(items: ackItems + items([assistantJSON("a2", "partial", runId: "r1")]),
                              isRunning: true, runId: "r1", agentReactions: [:]) == "u2", "the run's own output keeps the 👀")
    check(Reactions.ackTarget(items: ackItems + items([assistantJSON("a2", "cron", runId: "r9")]),
                              isRunning: true, runId: "r1", agentReactions: [:]) == nil, "a reply from another run after it → no 👀")
    check(Reactions.ackTarget(items: Array(ackItems.prefix(2)) + items([assistantJSON("a2", "later")]),
                              isRunning: true, runId: "r1", agentReactions: [:]) == nil, "never on older messages")
    check(Reactions.ackTarget(items: ackItems + [ChatItem(role: .user, blocks: [.text("new")], isPending: true)],
                              isRunning: true, runId: "r1", agentReactions: [:]) == nil, "a newer pending send → no 👀 on the old one")
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: [:],
                              config: ["messages": ["ackReactionScope": "none"]]) == nil,
          "explicit ACK scope none hides the temporary 👀")
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: [:],
                              config: ["messages": ["ackReaction": ""]]) == nil,
          "explicit empty effective ACK emoji hides the temporary 👀")
    check(Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: [:],
                              config: ["messages": ["ackReactionScope": "direct"]], chatType: "group") == nil
          && Reactions.ackTarget(items: ackItems, isRunning: true, runId: "r1", agentReactions: [:],
                                 config: ["messages": ["ackReactionScope": "group-all"]], chatType: "direct") == nil,
          "known direct/group scope mismatch hides the temporary 👀")
}

// MARK: Demo

private func pause(_ seconds: Double) async {
    // Demo pacing between scripted steps; not a wait on a condition.
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

/// The demo's recorded `message.action` calls, once there are at least `count` (or after `timeout`).
@MainActor
private func recordedActions(_ gateway: GatewayStore, atLeast count: Int, timeout: Double = 5) async -> [JSONValue] {
    let deadline = Date().addingTimeInterval(timeout)
    var actions = await gateway.demoRecordedActions()
    while actions.count < count, Date() < deadline {
        // Poll interval.
        try? await Task.sleep(for: .milliseconds(50))
        actions = await gateway.demoRecordedActions()
    }
    return actions
}

@MainActor
private func connectDemo(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor(label) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(label) connected")
    return connected ? gateway : nil
}

@MainActor
private func forgetLocalPrefs(_ store: GatewayStore) {
    for prefix in ["reactions", "reactionsSynced"] {
        UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(store.id.uuidString)")
    }
}

@MainActor
private func userItem(_ chat: ChatStore, containing text: String) -> [ChatItem] {
    chat.items.filter { $0.role == .user && $0.plainText.contains(text) }
}

@MainActor
func runDemoReactionsReply() async {
    guard let gateway = await connectDemo(.demo(), "demo for replies and reactions") else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    let main = "agent:main:main"
    let lab = "agent:main:discord:channel:123"
    let agentName = gateway.agents.first { $0.id == "main" }?.name ?? "Claw"
    check(gateway.supportsMessageAction, "demo advertises message.action")
    let chat = gateway.chat(for: main)
    await chat.load()
    _ = await waitFor("demo main history") { chat.message(withId: "demo-main-gauge-ask") != nil }
    check(chat.hasLoaded && chat.message(withId: "demo-main-status") != nil, "demo main history loaded with seeded ids")

    // Seeded agent reactions (AC-36, AC-38).
    check(chat.agentReactions["demo-main-ask"] == ["✅"]
          && chat.reactionGroups(for: "demo-main-ask", agentName: agentName).first == ReactionGroup(emoji: "✅", actors: [.agent(agentName)]),
          "✅ from \(agentName) on the disk question (\(chat.agentReactions))")
    let labChat = gateway.chat(for: lab)
    await labChat.load()
    check(labChat.message(withId: "demo-lab-sensor")?.channelMessageId == "1300000000000000001"
          && labChat.message(withId: "demo-lab-sensor")?.conversationRef == "channel:123", "home-lab sensor message carries its Discord id")
    check(labChat.agentReactions == ["demo-lab-sensor": ["👀"]], "👀 from \(agentName) on the sensor message (\(labChat.agentReactions))")

    // Seeded shared reactions arrive through session.reactions.list, and the legacy prefs move over (#120).
    let listed = await waitFor("seeded shared reactions") { chat.usesGatewayReactions && chat.sharedReactions["demo-main-status"] != nil }
    check(listed && chat.reactionSelfId == "demo-owner", "listed through session.reactions.list as \(chat.reactionSelfId ?? "nobody")")
    let statusGroups = chat.reactionGroups(for: "demo-main-status", agentName: agentName)
    check(statusGroups == [ReactionGroup(emoji: "👍", actors: [.you, .person("Sam")]), ReactionGroup(emoji: "🔥", actors: [.person("Riley")])],
          "seeded 👍 is yours next to Sam's; 🔥 is Riley's (\(statusGroups))")
    check(chat.reactionGroups(for: "demo-main-ask", agentName: agentName)
          == [ReactionGroup(emoji: "✅", actors: [.agent(agentName)]), ReactionGroup(emoji: "🙏", actors: [.person("Sam")])],
          "the agent's inferred ✅ merges with Sam's 🙏")
    let migrated = await waitFor("legacy prefs migrated") { chat.reactionSync.migratedEpoch == gateway.connectionEpoch && gateway.reactions.isEmpty }
    check(migrated, "the seeded pincer.reactions entries were pushed and deleted (\(gateway.reactions))")
    check(Reactions.mine(in: chat.sharedReactions["demo-main-gauge"] ?? [], selfId: "demo-owner") == ["🎉"],
          "the legacy 🎉 on the gauge moved over as yours")
    check(chat.reactionGroups(for: "demo-main-gauge", agentName: agentName) == [ReactionGroup(emoji: "🎉", actors: [.person("Sam"), .person("Riley"), .you])],
          "…next to Sam's and Riley's")

    // Seeded quoted reply (AC-37).
    let ask = chat.message(withId: "demo-main-gauge-ask")
    check(ask?.replyToId == "demo-main-status" && ask?.replyToPreview?.senderLabel == "Claw"
          && ask?.replyToPreview?.text.hasPrefix("Disk status") == true, "gauge question replies to the disk status")
    if let ask, let quote = chat.quote(for: ask) {
        check(quote.targetId == "demo-main-status" && quote.sender == .agent && quote.text?.isEmpty == false,
              "quote resolves the loaded original (\(quote.text ?? "nil"))")
    } else {
        check(false, "gauge question has a quote")
    }
    let before = chat.items.count
    let located = await chat.locate("demo-main-status")
    check(located && chat.items.count == before && chat.locatingReplyId == nil, "locating a loaded message doesn't page")

    // Replying persists replyToId and a preview (AC-40).
    guard let target = chat.replyTarget(for: "demo-main-status", you: "You", agent: agentName) else {
        check(false, "reply target for the disk status")
        return
    }
    check(target.isAssistant && target.senderLabel == agentName && !target.preview.isEmpty, "reply target names the agent")
    check(chat.replyTarget(for: "nope", you: "You", agent: agentName) == nil, "no reply target for an unknown id")
    chat.replyTarget = target
    let nonce = UUID().uuidString.prefix(6)
    var sawAck = false
    await chat.send("nice gauge \(nonce)", replyTo: target)
    check(chat.replyTarget == nil, "an accepted reply clears the target")
    let pending = userItem(chat, containing: "nice gauge \(nonce)").first
    check(pending?.replyToId == "demo-main-status" && pending?.replyToPreview?.senderLabel == agentName,
          "the sent message shows its quote right away")
    let replied = await waitFor("demo reply to a reply", timeout: 20, every: 10) {
        if chat.isRunning, let ack = chat.ackMessageId, chat.message(withId: ack)?.plainText.contains("nice gauge \(nonce)") == true {
            sawAck = true
        }
        return !chat.isRunning && userItem(chat, containing: "nice gauge \(nonce)").first?.isPending == false
    }
    check(replied, "demo reply finished")
    check(sawAck, "👀 on your message while the demo reply streams (AC-41)")
    check(chat.ackMessageId == nil, "👀 gone once the run ends")
    await chat.load(force: true)
    let sent = userItem(chat, containing: "nice gauge \(nonce)")
    check(sent.count == 1 && sent[0].replyToId == "demo-main-status" && sent[0].replyToPreview?.senderLabel == agentName
          && sent[0].replyToPreview?.text.contains("Disk status") == true && !sent[0].plainText.hasPrefix(">"),
          "replyToId + replyToPreview persist after reload, text unquoted (\(sent.map { "\($0.replyToId ?? "nil") \($0.replyToPreview.map { "\($0.senderLabel ?? "nil"): \($0.text.prefix(30))" } ?? "nil")" }))")

    // Toggling goes through session.reactions.set (AC-29): optimistic, the round trip shows the other people's too.
    let actionsBefore = await gateway.demoRecordedActions().count
    chat.toggleReaction("✅", on: "demo-main-ask")
    let both = chat.reactionGroups(for: "demo-main-ask", agentName: agentName)
    check(both.first?.emoji == "✅" && both[0].count == 2 && both[0].includesYou && both[0].reactorsText == "You and \(agentName)", "your ✅ joins \(agentName)'s at once (\(both.first?.reactorsText ?? ""))")
    check(Reactions.recent.contains("✅"), "adding records a recent emoji")
    let confirmed = await waitFor("set round trip") { Reactions.mine(in: chat.sharedReactions["demo-main-ask"] ?? [], selfId: "demo-owner") == ["✅"] }
    check(confirmed && chat.sharedReactions["demo-main-ask"]?.first { $0.emoji == "🙏" }?.identities.map(\.label) == ["Sam"],
          "the Gateway's reply keeps Sam's 🙏 (\(chat.sharedReactions["demo-main-ask"] ?? []))")
    chat.toggleReaction("🔥", on: "demo-main-ask")
    chat.toggleReaction("✅", on: "demo-main-ask")
    chat.toggleReaction("🔥", on: "demo-main-ask")
    let cleared = await waitFor("toggle off") { Reactions.mine(in: chat.sharedReactions["demo-main-ask"] ?? [], selfId: "demo-owner").isEmpty }
    check(cleared && chat.reactionGroups(for: "demo-main-ask", agentName: agentName)
          == [ReactionGroup(emoji: "✅", actors: [.agent(agentName)]), ReactionGroup(emoji: "🙏", actors: [.person("Sam")])],
          "toggling off leaves the agent's ✅ and Sam's 🙏 alone")
    chat.toggleReaction("👍", on: "not-loaded")
    check(chat.sharedReactions["not-loaded"] == nil && chat.notice == nil, "unknown messages can't be reacted to")
    // Removing your seeded 👍 keeps Sam's.
    chat.toggleReaction("👍", on: "demo-main-status")
    check(chat.reactionGroups(for: "demo-main-status", agentName: agentName).first == ReactionGroup(emoji: "👍", actors: [.person("Sam")]),
          "removing your 👍 leaves Sam's")
    chat.toggleReaction("👍", on: "demo-main-status")
    _ = await waitFor("👍 back") { Reactions.mine(in: chat.sharedReactions["demo-main-status"] ?? [], selfId: "demo-owner") == ["👍"] }

    // The Gateway mirrors to the channel: no message.action from Pincer, bridged or not (AC-30, AC-31).
    labChat.toggleReaction("👍", on: "demo-lab-sensor")
    let sensorMine = await waitFor("sensor reaction") { Reactions.mine(in: labChat.sharedReactions["demo-lab-sensor"] ?? [], selfId: "demo-owner") == ["👍"] }
    labChat.toggleReaction("👍", on: "demo-lab-sensor")
    await pause(0.5)
    let actions = await gateway.demoRecordedActions().count
    check(sensorMine && actions == actionsBefore, "no message.action on the Gateway path (\(actions - actionsBefore) sent)")
    check(labChat.notice == nil && chat.notice == nil && gateway.reactions.isEmpty, "no notice, and users.prefs stays empty")

    // A failed set rolls back and says so; an unknown message isn't a reason to leave the Gateway path.
    var phantom = ChatItem(role: .assistant, blocks: [.text("phantom")])
    phantom.transcriptId = "phantom-message"
    chat.items.append(phantom)
    chat.toggleReaction("🎯", on: "phantom-message")
    check(chat.sharedReactions["phantom-message"] != nil, "optimistic before the failure")
    let rolledBack = await waitFor("rollback") { chat.sharedReactions["phantom-message"] == nil && chat.notice != nil }
    check(rolledBack && chat.notice == "Couldn't save the reaction." && chat.usesGatewayReactions && !gateway.sessionReactionsOff,
          "rolled back with a notice, still on the Gateway path (\(chat.notice ?? "no notice"))")
    chat.items.removeAll { $0.transcriptId == "phantom-message" }
    chat.notice = nil

    // An unavailable Gateway path (FORBIDDEN, unknown method, no identified author) falls back to users.prefs, once.
    gateway.sessionReactionsOff = true
    check(!chat.usesGatewayReactions, "Gateway reactions off → the chat is back on users.prefs")

    // An older Gateway: quote in the text instead (AC-15).
    guard let old = await connectDemo(.demo(acceptsReplyTo: false), "demo without replyToId") else { return }
    defer {
        old.stop()
        forgetLocalPrefs(old)
    }
    let oldChat = old.chat(for: main)
    await oldChat.load()
    _ = await waitFor("older demo history") { oldChat.message(withId: "demo-main-status") != nil }
    guard let oldTarget = oldChat.replyTarget(for: "demo-main-status", you: "You", agent: agentName) else {
        check(false, "reply target on the older demo")
        return
    }
    check(!old.replyToUnsupported, "replyToId assumed until rejected")
    oldChat.replyTarget = oldTarget
    let oldNonce = UUID().uuidString.prefix(6)
    let runId = await oldChat.send("quoted \(oldNonce)", replyTo: oldTarget)
    check(runId != nil && oldChat.errorMessage == nil && old.replyToUnsupported && oldChat.replyTarget == nil,
          "rejected replyToId → resent once without it, no error (\(oldChat.errorMessage ?? "ok"))")
    _ = await waitFor("older demo reply", timeout: 20) { !oldChat.isRunning && userItem(oldChat, containing: "quoted \(oldNonce)").first?.isPending == false }
    await oldChat.load(force: true)
    let quotedSent = userItem(oldChat, containing: "quoted \(oldNonce)")
    check(quotedSent.count == 1 && quotedSent[0].plainText.hasPrefix("> **\(agentName):** ") && quotedSent[0].replyToId == nil
          && quotedSent[0].plainText.hasSuffix("\n\nquoted \(oldNonce)"), "one message, text starts with the blockquote (\(quotedSent.first?.plainText.prefix(40) ?? "none"))")
    let secondNonce = UUID().uuidString.prefix(6)
    await oldChat.send("again \(secondNonce)", replyTo: oldTarget)
    _ = await waitFor("second older demo reply", timeout: 20) { !oldChat.isRunning && userItem(oldChat, containing: "again \(secondNonce)").first?.isPending == false }
    await oldChat.load(force: true)
    let again = userItem(oldChat, containing: "again \(secondNonce)")
    check(again.count == 1 && again[0].plainText.hasPrefix("> **") && oldChat.errorMessage == nil,
          "later sends skip replyToId and quote straight away")
}

/// Reactions when the Gateway path is off for the connection (an older Gateway, FORBIDDEN or no identified author):
/// users.prefs, with message.action forwarding for bridged messages.
@MainActor
func runDemoPrefsReactions() async {
    guard let gateway = await connectDemo(.demo(hasSessionReactions: false), "demo without session.reactions") else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    let main = "agent:main:main"
    let lab = "agent:main:discord:channel:123"
    let agentName = gateway.agents.first { $0.id == "main" }?.name ?? "Claw"
    let chat = gateway.chat(for: main)
    await chat.load()
    _ = await waitFor("demo main history") { chat.message(withId: "demo-main-status") != nil }
    let labChat = gateway.chat(for: lab)
    await labChat.load()
    check(!gateway.supportsSessionReactions && !chat.usesGatewayReactions && chat.sharedReactions.isEmpty, "the Gateway path is off")
    // Seeded user reactions arrive through users.prefs (AC-39).
    let seeded = await waitFor("seeded reactions") {
        gateway.myReactions(sessionKey: main, messageId: "demo-main-status") == ["👍"]
            && gateway.myReactions(sessionKey: main, messageId: "demo-main-gauge") == ["🎉"]
    }
    check(seeded, "👍 and 🎉 pre-seeded in pincer.reactions (\(gateway.reactions))")
    check(chat.reactionGroups(for: "demo-main-status", agentName: agentName).contains { $0.emoji == "👍" && $0.includesYou }, "seeded 👍 is yours")

    // Toggling your reactions updates pincer.reactions (AC-29).
    let prefKey = Reactions.prefEntryKey(sessionKey: main, messageId: "demo-main-ask")
    chat.toggleReaction("✅", on: "demo-main-ask")
    check(gateway.reactions[prefKey] == "✅", "toggle on → pincer.reactions entry")
    let both = chat.reactionGroups(for: "demo-main-ask", agentName: agentName)
    check(both.count == 1 && both[0].count == 2 && both[0].includesYou && both[0].reactorsText == "You and \(agentName)",
          "your ✅ joins \(agentName)'s (\(both.first?.reactorsText ?? ""))")
    // The recent list lives in this process's standard defaults, which parallel check runs share
    // (#206), so another run may have recorded after this one: check membership, not position.
    check(Reactions.recent.contains("✅"), "adding records a recent emoji")
    chat.toggleReaction("🔥", on: "demo-main-ask")
    check(gateway.reactions[prefKey] == "✅ 🔥", "emoji kept in the order added")
    chat.toggleReaction("✅", on: "demo-main-ask")
    chat.toggleReaction("🔥", on: "demo-main-ask")
    check(gateway.reactions[prefKey] == nil && !gateway.reactions.keys.contains(prefKey), "toggle off the last emoji → key removed")
    check(chat.reactionGroups(for: "demo-main-ask", agentName: agentName) == [ReactionGroup(emoji: "✅", actors: [.agent(agentName)])],
          "the agent's reaction can't be removed by yours")
    chat.toggleReaction("👍", on: "not-loaded")
    check(!gateway.reactions.keys.contains(Reactions.prefEntryKey(sessionKey: main, messageId: "not-loaded")), "unknown messages can't be reacted to")

    // Legacy Gateways enforce a 4 KiB users.prefs value cap. A burst of older reactions must be
    // bounded before the current gesture is written, rather than leaving pincer.reactions rejected.
    let latestLegacyKey = Reactions.prefEntryKey(sessionKey: main, messageId: "legacy-cap-139")
    for index in 0..<140 {
        gateway.setReactions(["👍"], sessionKey: main, messageId: "legacy-cap-\(index)")
    }
    _ = await waitFor("legacy reaction preference sync settled") {
        gateway.remotePrefMaps[Reactions.prefKey]?[latestLegacyKey] == "👍"
            || gateway.rejectedPrefs[Reactions.prefKey] != nil
    }
    await gateway.prefPushes[Reactions.prefKey]?.value
    let remoteReactions = gateway.remotePrefMaps[Reactions.prefKey]
    let remoteReactionBytes = remoteReactions.flatMap { try? JSONEncoder().encode($0).count } ?? Int.max
    check(remoteReactionBytes <= LegacyReactionPrefs.syncedByteBudget,
          "legacy reaction prefs fit the sync budget (\(remoteReactionBytes) bytes)")
    check(remoteReactions?[latestLegacyKey] == "👍" && gateway.rejectedPrefs[Reactions.prefKey] == nil,
          "the latest legacy reaction reaches users.prefs without a rejected sync")

    // Forwarding: home-lab sensor forwards, Main doesn't (AC-30, AC-31).
    let actionsBefore = await gateway.demoRecordedActions().count
    chat.toggleReaction("🎉", on: "demo-main-status")
    chat.toggleReaction("🎉", on: "demo-main-status")
    labChat.toggleReaction("👍", on: "demo-lab-sensor")
    await pause(0.5)
    let actions = await recordedActions(gateway, atLeast: actionsBefore + 1).dropFirst(actionsBefore)
    check(actions.count == 1, "only the bridged sensor reaction calls message.action (\(actions.count))")
    if let action = actions.first {
        check(action["channel"]?.string == "discord" && action["action"]?.string == "react" && action["sessionKey"]?.string == lab
              && action["params"] == ["messageId": "1300000000000000001", "emoji": "👍", "to": "channel:123"]
              && action["idempotencyKey"]?.string?.isEmpty == false, "message.action react params")
    }
    labChat.toggleReaction("👍", on: "demo-lab-sensor")
    let removals = await recordedActions(gateway, atLeast: actionsBefore + 2).dropFirst(actionsBefore + 1)
    check(removals.count == 1 && removals.first?["params"]?["remove"]?.bool == true,
          "removing is forwarded with remove: true (\(removals.map { $0["params"].map { "\($0)" } ?? "-" }))")
    check(labChat.notice == nil && chat.notice == nil && gateway.myReactions(sessionKey: lab, messageId: "demo-lab-sensor").isEmpty,
          "successful forwarding shows no notice (\(labChat.notice ?? chat.notice ?? "none"), \(gateway.myReactions(sessionKey: lab, messageId: "demo-lab-sensor")))")
    let replyTargetAssistant = labChat.items.last { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty }?.transcriptId
    if let replyTargetAssistant {
        labChat.toggleReaction("👍", on: replyTargetAssistant)
        labChat.toggleReaction("👍", on: replyTargetAssistant)
        await pause(0.5)
        let total = await gateway.demoRecordedActions().count
        check(total == actionsBefore + 2, "assistant messages in bridged chats are Pincer-only")
    }

}

// MARK: Live

@MainActor
private func connectLive(_ name: String, url: String, token: String) async -> GatewayStore? {
    let profile = GatewayProfile(name: name, url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor(name, timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(name) connected")
    return connected ? gateway : nil
}

@MainActor
func runLiveReactionsReply(url: String, token: String) async {
    guard let gateway = await connectLive("Mock replies", url: url, token: token) else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    let main = "agent:main:main"
    let lab = "agent:main:discord:channel:123"
    let agentName = gateway.agents.first { $0.id == "main" }?.name ?? "Claw"
    check(gateway.supportsMessageAction, "mock advertises message.action")

    // chat.send with replyToId (AC-42, AC-48).
    let chat = gateway.chat(for: main)
    await chat.load()
    // Connecting selects Main and loads it; a second load returns while that one is in flight.
    _ = await waitFor("main history") { chat.items.contains { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty } }
    guard let targetId = chat.items.last(where: { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty })?.transcriptId,
          let target = chat.replyTarget(for: targetId, you: "You", agent: agentName)
    else {
        check(false, "an assistant message to reply to")
        return
    }
    let nonce = UUID().uuidString.prefix(6)
    await chat.send("live reply \(nonce)", replyTo: target)
    let finished = await waitFor("live reply", timeout: 20) {
        !chat.isRunning && userItem(chat, containing: "live reply \(nonce)").first?.isPending == false
    }
    check(finished, "reply sent and finished")
    await chat.load(force: true)
    let sent = userItem(chat, containing: "live reply \(nonce)")
    check(sent.count == 1 && sent[0].replyToId == targetId && sent[0].replyToPreview?.senderLabel == agentName
          && sent[0].replyToPreview?.text.isEmpty == false && sent[0].plainText == "live reply \(nonce)",
          "history has __openclaw.replyToId and a preview from \(sent.first?.replyToPreview?.senderLabel ?? "nobody")")
    if let own = sent.first?.transcriptId, let ownTarget = chat.replyTarget(for: own, you: "You", agent: agentName) {
        let ownNonce = UUID().uuidString.prefix(6)
        await chat.send("about mine \(ownNonce)", replyTo: ownTarget)
        _ = await waitFor("reply to own", timeout: 20) { !chat.isRunning && userItem(chat, containing: "about mine \(ownNonce)").first?.isPending == false }
        await chat.load(force: true)
        let ownReply = userItem(chat, containing: "about mine \(ownNonce)").first
        check(ownReply?.replyToId == own && ownReply?.replyToPreview?.senderLabel?.isEmpty == false
              && chat.quote(for: ownReply!)?.sender == .you, "reply to your own message: quote says you")
    }

    // Locating an old trip message pages older history (AC-19).
    let trip = gateway.chat(for: "agent:main:dashboard:trip")
    await trip.load()
    // Opening a chat backfills older pages; wait for the start.
    _ = await waitFor("trip backfill", timeout: 20) { !trip.hasMoreHistory }
    let oldId = trip.items.first?.transcriptId
    check(oldId != nil && trip.items.count > 120 && trip.items.first?.plainText == "Idea for day 1?",
          "found the oldest trip message (\(trip.items.count))")
    let fresh = await connectLive("Mock locate", url: url, token: token)
    if let fresh, let oldId {
        let freshTrip = fresh.chat(for: "agent:main:dashboard:trip")
        await freshTrip.load()
        check(freshTrip.message(withId: oldId) == nil && freshTrip.items.count == 120, "old message not in the first page")
        let channelId = await freshTrip.locateReplyTarget("7421093845")
        check(!channelId && freshTrip.locatingReplyId == nil
              && freshTrip.notice == "The original message isn't in this chat's history anymore.",
              "a channel message id fails fast with a notice (quote taps)")
        freshTrip.notice = nil
        let found = await freshTrip.locate(oldId)
        check(found && freshTrip.message(withId: oldId) != nil && freshTrip.items.count > 120 && freshTrip.notice == nil,
              "locate pages until found (\(freshTrip.items.count))")
        let missing = await freshTrip.locate("not-a-message")
        check(!missing && !freshTrip.hasMoreHistory && freshTrip.notice == "The original message isn't in this chat's history anymore.",
              "missing original → notice once history runs out")
        fresh.stop()
        forgetLocalPrefs(fresh)
    }

    // The mock's seeded 👀 derives onto the Discord user message (AC-45).
    let labChat = gateway.chat(for: lab)
    await labChat.load()
    guard let sensor = labChat.items.first(where: { $0.channelMessageId == "1300000000000000001" }), let sensorId = sensor.transcriptId else {
        check(false, "discord user message with its channel id")
        return
    }
    check(sensor.role == .user && sensor.transportChannel == "discord" && sensor.conversationRef == "channel:123", "transport facts from history")
    check(labChat.agentReactions[sensorId] == ["👀"], "seeded 👀 derives onto the Discord message (\(labChat.agentReactions))")
}

/// Against a Gateway from before replies (mock with MOCK_NO_REPLY_TO=1): replies quote instead.
@MainActor
func runLiveNoReplyTo(url: String, token: String) async {
    guard let gateway = await connectLive("Mock without replyToId", url: url, token: token) else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    _ = await waitFor("main history") { chat.items.contains { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty } }
    let agentName = gateway.agents.first { $0.id == "main" }?.name ?? "Claw"
    guard let targetId = chat.items.last(where: { $0.role == .assistant && $0.isReplyable && !$0.plainText.isEmpty })?.transcriptId,
          let target = chat.replyTarget(for: targetId, you: "You", agent: agentName)
    else {
        check(false, "an assistant message to reply to")
        return
    }
    for (index, label) in ["first", "second"].enumerated() {
        let nonce = "\(label) \(UUID().uuidString.prefix(6))"
        chat.replyTarget = target
        let runId = await chat.send(nonce, replyTo: target)
        check(runId != nil && chat.errorMessage == nil && gateway.replyToUnsupported && chat.replyTarget == nil,
              "\(label) reply accepted without an error (\(chat.errorMessage ?? "ok"))")
        _ = await waitFor("\(label) reply", timeout: 20) { !chat.isRunning && userItem(chat, containing: nonce).first?.isPending == false }
        await chat.load(force: true)
        let sent = userItem(chat, containing: nonce)
        check(sent.count == 1 && sent[0].replyToId == nil && sent[0].plainText.hasPrefix("> **\(agentName):** ")
              && sent[0].plainText.hasSuffix("\n\n\(nonce)"),
              index == 0 ? "rejected replyToId → one message quoting the original" : "later sends quote straight away")
    }
}

// MARK: Agent reply targets (#110)

private func deliveryAssistant(_ id: String, _ text: String, delivery: String? = nil, structured: String? = nil) -> ChatItem? {
    let delivery = delivery.map { #","openclawDelivery":\#($0)"# } ?? ""
    let structured = structured.map { #","replyToId":"\#($0)""# } ?? ""
    return item(#"{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]\#(delivery),"__openclaw":{"id":"\#(id)"\#(structured)}}"#)
}

@MainActor
func checkReplyTargets() {
    // Parsing: delivery facts on assistant messages only, structured id wins.
    check(deliveryAssistant("a1", "x", delivery: #"{"replyToId":" u1 "}"#)?.replyToId == "u1", "openclawDelivery.replyToId parses (trimmed)")
    check(deliveryAssistant("a2", "x", delivery: #"{"replyToCurrent":true}"#)?.replyToCurrent == true
          && deliveryAssistant("a3", "x", delivery: #"{"replyToCurrent":false}"#)?.replyToCurrent == false
          && deliveryAssistant("a4", "x")?.replyToCurrent == false, "openclawDelivery.replyToCurrent parses")
    check(deliveryAssistant("a5", "x", delivery: #"{"replyToId":"d"}"#, structured: "s")?.replyToId == "s", "__openclaw.replyToId beats the delivery target")
    let user = item(#"{"role":"user","content":[{"type":"text","text":"x"}],"openclawDelivery":{"replyToId":"a1","replyToCurrent":true},"__openclaw":{"id":"u1"}}"#)
    check(user?.replyToId == nil && user?.replyToCurrent == false, "delivery facts aren't read on user messages")

    // Directives.
    let byId = Replies.extractDirective("[[reply_to:abc-123]] Recovered answer")
    check(byId.target == .id("abc-123") && byId.text == "Recovered answer", "[[reply_to:id]] is extracted and stripped (\(byId))")
    let current = Replies.extractDirective("[[reply_to_current]] Ready")
    check(current.target == .current && current.text == "Ready", "[[reply_to_current]] is extracted and stripped")
    let multiple = Replies.extractDirective("[[reply_to:first]] First [[reply_to:second]] second")
    check(multiple.target == .id("first") && !multiple.text.contains("[[reply_to:") && multiple.text.contains("First") && multiple.text.contains("second"),
          "multiple reply directives are stripped while the first target is retained")
    let (streamDefaults, streamSuite) = scratchDefaults()
    defer { streamDefaults.removePersistentDomain(forName: streamSuite) }
    let streamGateway = GatewayStore(profile: .demo(), defaults: streamDefaults, identity: DeviceIdentity.loadOrCreate())
    let streamChat = ChatStore(sessionKey: "agent:main:main", agentId: nil, gateway: streamGateway, headless: true)
    streamChat.handleChat(["runId": "reply-check", "sessionKey": "agent:main:main", "seq": 0, "state": "delta",
                           "deltaText": .string("[[reply_to:first]] First [[reply_to:second]] second")])
    check(streamChat.live?.text == "First  second", "snapshotless stream removes every reply directive in a frame")
    check(Replies.extractDirective("[[ reply_to : 123 ]]ok").target == .id("123") && Replies.extractDirective("[[ reply_to : 123 ]]ok").text == "ok",
          "whitespace variants")
    let padded = Replies.extractDirective("[[reply_to:\nid\n ]]Visible reply")
    check(padded.target == .id("id") && padded.text == "Visible reply", "newline padding inside the tag is accepted like upstream (\(padded))")
    let plainText = Replies.extractDirective("  keep  ")
    check(plainText.target == nil && plainText.text == "  keep  ", "plain text is untouched")
    check(Replies.extractDirective("[[reply_to:message-7 Visible reply").target == nil
          && Replies.extractDirective("Visible\n[[reply_to_current] literally").target == nil
          && Replies.extractDirective("Use `[[reply_to_current]]` here").target == nil, "malformed and code-span directives stay literal")
    let leaked = deliveryAssistant("a6", "[[reply_to:u1]] Here you go")
    check(leaked?.replyToId == "u1" && leaked?.plainText == "Here you go", "a leaked directive supplies the target and is stripped from the text")
    check(deliveryAssistant("a7", "[[reply_to:x]] hi", delivery: #"{"replyToId":"d"}"#)?.replyToId == "d", "delivery beats a leaked directive")
}

/// The seeded Telegram chat both the demo and the mock carry: an answer to an earlier message,
/// one to the latest message, and one with a leaked directive.
@MainActor
private func checkTelegramReplyShapes(_ chat: ChatStore, idPrefix: String, label: String) async {
    await chat.load()
    let loaded = await waitFor("\(label) telegram history") { chat.items.contains { $0.plainText.hasPrefix("Dr. Alvarez") } }
    check(loaded, "\(label): bridged Telegram chat loads")
    let mayaMessages = chat.items.filter { $0.role == .user }
    check(!mayaMessages.isEmpty && mayaMessages.allSatisfy {
        $0.senderName(you: "Device Owner", agent: "Claw", agents: []) == "Maya"
    }, "\(label): every seeded Telegram user row resolves to Maya instead of the device owner")
    let clinic = chat.items.first { $0.role == .assistant && $0.plainText.hasPrefix("Dr. Alvarez") }
    let dentist = chat.items.first { $0.role == .assistant && $0.plainText.hasPrefix("Your dentist appointment") }
    let pickup = chat.items.first { $0.role == .assistant && $0.plainText.contains("Friday pickup") }
    check(clinic?.replyToId == "\(idPrefix)-clinic" && clinic?.replyToCurrent == false, "\(label): delivery replyToId parsed (\(clinic?.replyToId ?? "nil"))")
    if let clinic, let quote = chat.quote(for: clinic) {
        check(quote.targetId == "\(idPrefix)-clinic" && quote.sender == .label("Maya") && quote.text?.hasPrefix("Can you find") == true,
              "\(label): the answer to the earlier message shows a quote card naming Maya (\(quote.sender), \(quote.text ?? "nil"))")
    } else {
        check(false, "\(label): quote card on the seeded assistant reply")
    }
    check(dentist?.replyToCurrent == true && dentist.flatMap { chat.quote(for: $0) } == nil, "\(label): replyToCurrent → no quote")
    check(pickup?.replyToCurrent == true && pickup?.plainText.contains("[[") == false && pickup?.plainText.hasPrefix("Friday pickup is at 3:15") == true
          && pickup.flatMap { chat.quote(for: $0) } == nil, "\(label): leaked [[reply_to_current]] is stripped (\(pickup?.plainText.prefix(30) ?? "nil"))")
    let reloaded = chat.items.first { $0.id == clinic?.id }
    check(reloaded?.replyToId == clinic?.replyToId, "\(label): stable across items")
}

@MainActor
func runDemoReplyTargets() async {
    guard let gateway = await connectDemo(.demo(), "demo for reply targets") else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    let chat = gateway.chat(for: "agent:main:telegram:home:direct:5550142")
    await checkTelegramReplyShapes(chat, idPrefix: "demo-tg", label: "demo")
    if let latestUser = chat.items.last(where: { $0.role == .user }) {
        check(Reactions.ackTarget(items: [latestUser], isRunning: true, runId: "demo-ack", agentReactions: [:],
                                  config: ["messages": ["ackReactionScope": "off"]],
                                  channel: "telegram", account: "home") == nil
              && Reactions.ackTarget(items: [latestUser], isRunning: true, runId: "demo-ack", agentReactions: [:],
                                     channel: "telegram", account: "home") == latestUser.transcriptId,
              "demo chat suppresses only an explicitly disabled ACK")
    } else {
        check(false, "demo chat has a latest user turn for ACK policy")
    }
}

@MainActor
func runLiveReplyTargets(url: String, token: String) async {
    guard let gateway = await connectLive("Mock reply targets", url: url, token: token) else { return }
    defer {
        gateway.stop()
        forgetLocalPrefs(gateway)
    }
    await checkTelegramReplyShapes(gateway.chat(for: "agent:main:telegram:home:direct:5550142"), idPrefix: "mock-tg", label: "mock")
}
