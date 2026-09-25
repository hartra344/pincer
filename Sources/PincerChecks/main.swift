import Foundation
import PincerKit

// Self-checks that run without XCTest (unavailable with Command Line Tools only).
//   swift run PincerChecks                  → unit checks
//   swift run PincerChecks --live URL TOKEN → end-to-end against a (mock) Gateway
// Run with PINCER_KEYCHAIN=memory so nothing touches the real Keychain.

var failures = 0
var passes = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
    if condition() {
        passes += 1
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)  (line \(line))")
    }
}

func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

print("Payload & identity")
check(
    DeviceAuthPayload.v2(deviceId: "d", clientId: "openclaw-macos", clientMode: "ui", role: "operator",
                         scopes: ["operator.read", "operator.write"], signedAtMs: 42, token: nil, nonce: "n")
        == "v2|d|openclaw-macos|ui|operator|operator.read,operator.write|42||n",
    "v2 payload layout, empty token")
let identity = DeviceIdentity.loadOrCreate()
check(identity.deviceId.count == 64, "deviceId is sha256 hex")
check(DeviceIdentity.loadOrCreate().deviceId == identity.deviceId, "identity persists")
check(!identity.publicKeyBase64Url.contains("=") && !identity.publicKeyBase64Url.contains("+"), "public key is base64url")

print("URL policy")
func resolves(_ url: String) -> String? {
    try? GatewayProfile(name: "t", url: url, authMode: .token).resolvedURL().absoluteString
}
check(resolves("home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "bare .ts.net → wss")
check(resolves("100.101.102.103:18789") == "ws://100.101.102.103:18789", "tailnet IP → ws")
check(resolves("ws://127.0.0.1:18789") != nil, "loopback ws allowed")
check(resolves("ws://192.168.1.5:18789") != nil, "LAN ws allowed")
check(resolves("ws://example.com") == nil, "public ws rejected")
check(resolves("wss://example.com") != nil, "public wss allowed")
check(resolves("https://home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "https → wss")
check(resolves("ftp://x") == nil, "other schemes rejected")

print("Session rows")
let row = SessionRow(json("""
{"key":"agent:research:dashboard:x","label":"Papers","pinned":true,"unread":true,"channel":"discord",
 "parentSessionKey":"agent:research:main","lastActivityAt":1700000000000,"updatedAt":1600000000000}
"""))!
check(row.agentId == "research", "agentId from key")
check(row.title == "Papers" && row.isPinned && row.isUnread, "title/pinned/unread")
check(row.parentKey == "agent:research:main", "parent key → thread")
check(row.originLabel == "Discord", "origin label")
check(row.activityMs == 1_700_000_000_000, "activity uses latest timestamp")
check(SessionRow(json(#"{"label":"no key"}"#)) == nil, "rows without key rejected")

print("Discord channels")
let discord = SessionRow(json(##"{"key":"agent:main:discord:channel:1300000000000000001","displayName":"1100000000000000001 #finances","channel":"discord","chatType":"channel","groupChannel":"#finances","space":"1100000000000000001","origin":{"label":"Home Lab #finances channel id:1300000000000000001","provider":"discord","chatType":"channel"}}"##))!
check(discord.title == "finances", "guild-id prefix dropped from channel title (got \(discord.title))")
check(discord.server?.id == "1100000000000000001" && discord.server?.name == "Home Lab", "server id and name from origin")
let bare = SessionRow(json(#"{"key":"k","displayName":"1100000000000000001 #gyms","label":"1100000000000000001 #gyms","chatType":"channel","channel":"discord","space":"1100000000000000001"}"#))!
check(bare.title == "gyms", "generated label is cleaned (got \(bare.title))")
check(bare.server?.name == nil && bare.server?.displayName == "Discord", "unnamed server fallback")
let renamed = SessionRow(json(##"{"key":"k","label":"Money talk","groupChannel":"#finances","chatType":"channel","channel":"discord","space":"1"}"##))!
check(renamed.title == "Money talk", "user label wins")
let thread = SessionRow(json(##"{"key":"agent:main:discord:channel:1:thread:2","derivedTitle":"Todoist read for daily priorities","groupChannel":"#daily-tasks","chatType":"channel","channel":"discord","space":"1"}"##))!
check(thread.title == "Todoist read for daily priorities" && thread.isChannelThread, "Discord thread keeps its own title")
let direct = SessionRow(json(#"{"key":"agent:main:discord:direct:9","displayName":"Sam","chatType":"direct","channel":"discord"}"#))!
check(direct.server == nil && direct.title == "Sam", "DMs are not server channels")
let sub = SessionRow(json(#"{"key":"agent:main:subagent:1","spawnedBy":"agent:main:cron:job1:run:r1","label":"Uptown rentals","channel":"discord"}"#))!
check(sub.isSubagent && !discord.isSubagent && !row.isSubagent, "subagent detection by key")
check(sub.parentCandidates == ["agent:main:cron:job1:run:r1", "agent:main:cron:job1"], "automation run subagents fall back to the automation")
check(sub.server == nil, "subagents are not server channels")
let webReply = SessionRow(json(##"{"key":"agent:main:discord:channel:5","kind":"group","chatType":"direct","channel":"discord","groupChannel":"#gyms","space":"1","origin":{"provider":"webchat"}}"##))!
check(webReply.server?.provider == "discord" && webReply.title == "gyms", "channel stays in server after a web UI reply")
let slash = SessionRow(json(#"{"key":"agent:main:discord:slash:3","kind":"group","displayName":"1100000000000000001","channel":"discord","space":"1100000000000000001"}"#))!
check(slash.title == "Slash commands", "slash session titled (got \(slash.title))")
let newChat = SessionRow(json(#"{"key":"agent:main:dashboard:1","parentSessionKey":"agent:main:main","createdVia":"operator","spawnDepth":0}"#))!
check(newChat.isStandaloneChat && newChat.parentCandidates.isEmpty, "new chats started from main aren't nested under it")
let branch = SessionRow(json(#"{"key":"agent:main:dashboard:2","parentSessionKey":"agent:main:main","createdVia":"operator","forkedFromParent":true}"#))!
check(!branch.isStandaloneChat && branch.parentCandidates == ["agent:main:main"], "forks stay nested")
let channelChild = SessionRow(json(#"{"key":"agent:main:dashboard:3","parentSessionKey":"agent:main:discord:channel:5","createdVia":"operator"}"#))!
check(!channelChild.isStandaloneChat, "chats branched from a channel stay nested")
let automation = SessionRow(json(#"{"key":"agent:main:cron:job1","label":"Automation: Daily budget summary"}"#))!
check(automation.isAutomation && automation.title == "Daily budget summary", "automation title")

print("Media directives")
let media = MediaDirectives.extract(from: "Here's a real photograph of two mallard ducks.\nMEDIA:https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg\nPhoto: Richard Bartz / Wikimedia Commons.")
check(media.images.first?.url == "https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg", "MEDIA: URL becomes an image")
check(media.text == "Here's a real photograph of two mallard ducks.\nPhoto: Richard Bartz / Wikimedia Commons.", "directive line removed from text (got \(media.text))")
check(media.images.first?.alt == "Anas_platyrhynchos_male_female_quadrat.jpg", "image named after file")
let local = MediaDirectives.extract(from: "MEDIA: `/tmp/chart.png`\nMEDIA:~/report.pdf")
check(local.images.first?.url == "/tmp/chart.png" && local.files == ["report.pdf"], "local image + non-image file")
let fenced = MediaDirectives.extract(from: "```\nMEDIA:https://x.example/a.png\n```")
check(fenced.images.isEmpty, "directives inside code fences stay text")
check(MediaDirectives.withoutPartialDirective("Here:\nMEDIA:https://upl") == "Here:\n", "partial streamed directive hidden")
check(MediaDirectives.withoutPartialDirective("Done") == "Done", "normal streaming text untouched")
let turnEntries = TranscriptBuilder.build([ChatItem(json(#"{"role":"assistant","content":[{"type":"text","text":"Duck:\nMEDIA:https://e.example/d.webp"}]}"#), fallbackIndex: 0)!])
if case let .assistant(turn) = turnEntries.first {
    check(turn.images.count == 1 && turn.body == "Duck:", "transcript turn renders MEDIA as image")
} else {
    check(false, "assistant turn built")
}

print("Transcript")
let history = json("""
[
 {"role":"user","content":[{"type":"text","text":"check disk"}],"timestamp":1,"provenance":{"sourceChannel":"discord"},"__openclaw":{"id":"m1"}},
 {"role":"assistant","content":[{"type":"thinking","thinking":"Use df."},{"type":"toolCall","id":"c1","name":"exec","arguments":{"command":"df -h"}}],"__openclaw":{"id":"m2"}},
 {"role":"toolResult","toolCallId":"c1","toolName":"exec","content":[{"type":"text","text":"/ 50%"}],"__openclaw":{"id":"m3"}},
 {"role":"assistant","content":[{"type":"text","text":"Half full."},{"type":"image","artifactId":"a1","mimeType":"image/png","width":320,"height":200}],"__openclaw":{"id":"m4"}},
 {"role":"system","content":"ignored"},
 {"role":"user","content":"thanks","__openclaw":{"id":"m5"}}
]
""")
let items = history.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
check(items.count == 6, "parses all messages")
check(items[0].via == "Discord", "user provenance → via Discord")
let entries = TranscriptBuilder.build(items)
check(entries.count == 3, "user / assistant turn / user (got \(entries.count))")
if case let .assistant(turn) = entries[1] {
    check(turn.thinking == ["Use df."], "thinking folded into turn")
    check(turn.tools.count == 1 && turn.tools[0].result == "/ 50%", "tool call paired with result")
    check(turn.tools[0].arguments?.contains("df -h") == true, "tool arguments rendered")
    check(turn.body == "Half full.", "reply text")
    check(turn.images.first?.artifactId == "a1" && turn.images.first?.aspectRatio == 1.6, "image block")
} else {
    check(false, "second entry is an assistant turn")
}
check(ChatItem(json(#"{"role":"assistant","content":[],"errorMessage":"boom"}"#), fallbackIndex: 0)?.isError == true, "error-only assistant message")
let spawn = ToolActivity(id: "t", name: "sessions_spawn", arguments: #"{"label":"Find rentals","task":"x"}"#, result: nil, isError: false, isRunning: false)
check(spawn.spawnLabel == "Find rentals" && spawn.summary == nil, "spawn label derived once")
var sent = ToolActivity(id: "t2", name: "sessions_send", arguments: #"{"command":"ls"}"#, result: nil, isError: false, isRunning: false)
sent.result = #"{"sessionKey":"agent:main:subagent:1f2e-9a"}"#
check(sent.summary == "ls" && sent.spawnedSessionKey == "agent:main:subagent:1f2e-9a", "subagent key found in tool result")
check(ChatItem(json(#"{"role":"user","content":"hi","__openclaw":{"id":"abc"}}"#), fallbackIndex: 7)?.id == "abc", "row id is stable across pages")
let uploaded = ChatItem(json(#"{"role":"user","content":[{"type":"text","text":"look"}],"__openclaw":{"id":"u1","media":[{"path":"media://inbound/abc.png","contentType":"image/png","fileName":"Pasted Image.png","origin":"paste"},{"path":"media://inbound/doc.pdf","contentType":"application/pdf","fileName":"doc.pdf"}]}}"#), fallbackIndex: 0)
if case let .image(ref)? = uploaded?.blocks.dropFirst().first, case let .file(name, _)? = uploaded?.blocks.last {
    check(uploaded?.blocks.count == 3 && ref.url == "media://inbound/abc.png" && ref.alt == "Pasted Image.png" && name == "doc.pdf", "uploaded media facts show on user messages")
} else {
    check(false, "uploaded media facts show on user messages")
}
check(ChatItem(json(#"{"role":"user","content":[],"__openclaw":{"id":"u2","media":[{"path":"media://inbound/x.jpg","kind":"image"}]}}"#), fallbackIndex: 0)?.blocks.count == 1, "image-only upload keeps its row")
let stripped = json(##"""
[
 {"role":"assistant","content":[{"type":"thinking","thinking":""},{"type":"toolCall","id":"v1","name":"view_image","arguments":{"url":"https://x/y.jpg"}}],"__openclaw":{"id":"s1"}},
 {"role":"toolResult","toolCallId":"v1","toolName":"view_image","content":[{"type":"text","text":"Loaded 1 image"},{"type":"image","mimeType":"image/jpeg","bytes":226618,"omitted":true}],"__openclaw":{"id":"s2"}}
]
"""##)
if case let .assistant(turn) = TranscriptBuilder.build(stripped.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }).first {
    check(turn.images.isEmpty, "omitted tool-result images don't leave blank slots")
    check(turn.thinking.isEmpty, "empty thinking blocks are hidden")
} else {
    check(false, "omitted-image turn built")
}

print("Exec approvals")
let approval = ExecApproval(json(#"{"id":"ap1","request":{"command":"rm -rf build","cwd":"/p","sessionKey":"agent:main:main"},"expiresAtMs":1}"#))
check(approval?.id == "ap1" && approval?.command == "rm -rf build" && approval?.cwd == "/p", "approval payload")

// MARK: Live

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--live"), arguments.count > index + 2 {
    let url = arguments[index + 1]
    let token = arguments[index + 2]
    print("Live against \(url)")
    await runLive(url: url, token: token)
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

@MainActor
func waitFor(_ label: String, timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("    … timed out waiting for \(label)")
    return condition()
}

@MainActor
func runLive(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()

    var sawPairing = false
    let connected = await waitFor("connection", timeout: 25) {
        if case .awaitingPairing = gateway.state { sawPairing = true }
        return gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "connected and bootstrapped (pairing seen: \(sawPairing))")
    guard connected else { return }
    check(gateway.agents.count >= 3, "agents.list (\(gateway.agents.map(\.name)))")
    check(gateway.sessions.count >= 5, "sessions.subscribe (\(gateway.sessions.count) rows)")
    let sections = gateway.sections()
    check(sections.contains { $0.channels.contains { !$0.threads.isEmpty } }, "subagent session nested as thread")
    gateway.organization = .group
    check(gateway.sections().contains { $0.title == "Home" }, "group organization")
    gateway.organization = .agent

    let key = "agent:main:main"
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    let loaded = await waitFor("history") { chat.hasLoaded }
    check(loaded, "chat.history loaded")
    let turns = chat.entries.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { return turn }
        return nil
    }
    check(turns.contains { !$0.thinking.isEmpty }, "history includes thinking")
    check(turns.contains { !$0.tools.isEmpty && $0.tools.allSatisfy { $0.result != nil } }, "history includes paired tool results")
    if let image = turns.flatMap(\.images).first {
        gateway.images.load(image, sessionKey: key)
        let decoded = await waitFor("artifact") { gateway.images.cached(image) != nil }
        check(decoded, "artifacts.download → decoded image")
    } else {
        check(false, "history includes an image")
    }

    let trip = gateway.chat(for: "agent:main:dashboard:trip")
    await trip.load()
    let firstPage = trip.items.map(\.id)
    check(trip.hasMoreHistory && firstPage.count == 120, "latest page only (\(firstPage.count))")
    await trip.loadOlder()
    check(trip.items.count == 240 && Array(trip.items.suffix(120).map(\.id)) == firstPage,
          "older page prepended; newer rows keep their ids (\(trip.items.count))")
    await trip.load(force: true)
    check(trip.items.count >= 240, "tail reload keeps paged history (\(trip.items.count))")
    await trip.loadOlder()
    check(!trip.hasMoreHistory && trip.items.count == 302, "reaches the start (\(trip.items.count))")
    check(trip.items.first?.plainText == "Idea for day 1?", "oldest message first")

    let before = chat.entries.count
    let sendNonce = UUID().uuidString.prefix(8)
    await chat.send("show me a tool and an image please \(sendNonce)")
    var sawLive = false
    var sawLiveTool = false
    var sawLiveThinking = false
    let finished = await waitFor("run to finish", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming {
            sawLive = true
            if !turn.tools.isEmpty { sawLiveTool = true }
            if !turn.thinking.isEmpty { sawLiveThinking = true }
        }
        return sawLive && !chat.isRunning && chat.entries.count > before
    }
    check(finished, "chat.send streamed and finished")
    check(sawLiveThinking, "live thinking streamed")
    check(sawLiveTool, "live tool activity streamed")
    if case let .assistant(turn)? = chat.entries.last {
        check(!turn.isStreaming && !turn.body.isEmpty, "final reply committed from history")
        check(!turn.images.isEmpty, "final reply carries an image")
    } else {
        check(false, "last entry is the assistant reply")
    }
    let userTurns = chat.entries.filter { if case let .user(item) = $0 { item.plainText.contains("please \(sendNonce)") } else { false } }
    check(userTurns.count == 1, "optimistic send merged, not duplicated (\(userTurns.count))")

    await gateway.patch(key, ["pinned": true])
    let pinned = await waitFor("pin") { gateway.sessions[key]?.isPinned == true }
    check(pinned, "sessions.patch round-trips via sessions.changed")

    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval") { !gateway.approvals.isEmpty }
    check(approvalSeen, "exec approval surfaced")
    if let approval = gateway.approvals.first {
        await gateway.resolveApproval(approval, decision: "deny")
        check(gateway.approvals.isEmpty, "approval resolved")
    }

    let newKey = await gateway.createSession(agentId: "research", label: "Pincer check", category: "Work")
    check(newKey != nil && gateway.sessions[newKey ?? ""] != nil, "sessions.create")

    // Drag and drop between groups.
    if let newKey {
        let savedOrganization = gateway.organization
        gateway.organization = .group
        func section(_ id: String) -> SidebarSection? { gateway.sections().first { $0.id == id } }
        if let work = section("group:Work") {
            check(gateway.groupDropValue(for: newKey, onto: work) == nil, "drop onto its own group is ignored")
        }
        let home = SidebarSection(id: "group:Home", title: "Home", emoji: nil, channels: [], kind: .group("Home"))
        let didMove = await gateway.moveToGroup(newKey, droppedOn: home)
        check(didMove, "drop onto another group moves the chat")
        let moved = await waitFor("drop move") { gateway.sessions[newKey]?.category == "Home" }
        check(moved && section("group:Home")?.channels.contains { $0.id == newKey } == true, "dropped chat shows in its new group")
        let ungrouped = SidebarSection(id: "group:", title: "Ungrouped", emoji: nil, channels: [], kind: .other)
        let didUngroup = await gateway.moveToGroup(newKey, droppedOn: ungrouped)
        check(didUngroup, "drop onto Ungrouped")
        let removed = await waitFor("drop ungroup") { gateway.sessions[newKey]?.category == nil }
        check(removed, "drop onto Ungrouped removes the group")
        check(gateway.groupDropValue(for: newKey, onto: ungrouped) == nil, "ungrouped chat ignores Ungrouped drop")
        let recent = SidebarSection(id: "recent", title: "Recent", emoji: nil, channels: [], kind: .other)
        check(gateway.groupDropValue(for: newKey, onto: recent) == nil, "drop onto Recent is ignored")
        check(gateway.groupDropValue(for: "agent:nope:missing", onto: home) == nil, "unknown dropped key is ignored")
        // Like Discord: a grouped chat dropped on its home agent section leaves its group.
        gateway.organization = .servers
        await gateway.patch(newKey, ["category": "Work"])
        _ = await waitFor("regroup") { gateway.sessions[newKey]?.category == "Work" }
        let agentHome = SidebarSection(id: "agent:research", title: "Research", emoji: nil, channels: [], kind: .agent("research"))
        let otherAgent = SidebarSection(id: "agent:main", title: "Main", emoji: nil, channels: [], kind: .agent("main"))
        check(gateway.groupDropValue(for: newKey, onto: agentHome) == .null, "drop onto home agent section ungroups")
        check(gateway.groupDropValue(for: newKey, onto: otherAgent) == nil, "drop onto another agent is ignored")
        gateway.organization = savedOrganization
    }

    // A second device: names set on it before syncing are uploaded, and renames flow both ways.
    let otherProfile = GatewayProfile(name: "Mock 2", url: url, authMode: .token)
    otherProfile.secret = token
    let other = GatewayStore(profile: otherProfile)
    let early = ChatServer(provider: "discord", id: "server-early", name: nil)
    let renamed = ChatServer(provider: "discord", id: "server-renamed", name: nil)
    other.renameServer(early, to: "Set Before Sync")
    other.start()
    let otherConnected = await waitFor("second device") { other.state.isConnected && !other.sessions.isEmpty }
    check(otherConnected, "second device connected")
    let uploaded = await waitFor("first-sync upload") {
        gateway.displayName(for: early) == "Set Before Sync"
    }
    check(uploaded, "names set before syncing reach other devices")
    gateway.renameServer(renamed, to: "Synced Name")
    let synced = await waitFor("rename sync") { other.displayName(for: renamed) == "Synced Name" }
    check(synced, "server rename syncs through users.prefs")
    other.renameServer(renamed, to: nil)
    let cleared = await waitFor("rename clear") { gateway.displayName(for: renamed) != "Synced Name" }
    check(cleared, "clearing a server name syncs")
    // Chat icons sync the same way, through the `pincer.chatIcons` pref.
    if let iconKey = gateway.sessions.keys.sorted().first {
        gateway.setIcon("star.fill", for: iconKey)
        let iconSynced = await waitFor("icon sync") { other.customIcon(for: iconKey) == "star.fill" }
        check(iconSynced, "chat icon syncs through users.prefs")
        other.setIcon(nil, for: iconKey)
        let iconCleared = await waitFor("icon clear") { gateway.customIcon(for: iconKey) == nil }
        check(iconCleared, "clearing a chat icon syncs")
    }
    other.stop()
    for store in [gateway, other] {
        for prefix in ["serverNames", "serverNamesSynced", "chatIcons", "chatIconsSynced"] {
            UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(store.id.uuidString)")
        }
    }
    gateway.stop()
}
