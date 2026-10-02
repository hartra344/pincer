import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// Needs a mock started with MOCK_PAIRING=auto MOCK_LEGACY_PAIRING=1, so the first pairing
/// leaves out operator.questions and the next connect is refused as a scope upgrade.
@MainActor
func runScopeUpgrade(url: String, token: String) async {
    let profile = GatewayProfile(name: "Legacy", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor("connection after scope upgrade refusal", timeout: 30) {
        gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "legacy device still connects while its scope upgrade is pending")
    guard connected else { return }
    check(gateway.hello?.withheldScopes == [GatewayConnection.questionsScope] && !gateway.canAnswerQuestions,
          "connected without operator.questions (\(gateway.hello?.withheldScopes ?? []))")
    check(gateway.hello?.scopeUpgradeRequestId?.hasPrefix("pair_") == true, "upgrade request id kept for the hint")
    // The mock approves upgrades after 3 seconds; Try Again then picks up the new scope.
    // The mock approves the scope upgrade on a fixed 3 s timer; there is no event to await, so
    // Try Again is repeated until the upgrade lands.
    var upgraded = false
    let upgradeDeadline = Date().addingTimeInterval(60)
    while !upgraded, Date() < upgradeDeadline {
        try? await Task.sleep(for: .seconds(1))
        gateway.retryQuestionAccess()
        upgraded = await waitFor("questions scope after approval", timeout: 5) {
            gateway.state.isConnected && gateway.canAnswerQuestions
        }
    }
    check(upgraded, "retry after approval gains operator.questions")
    check(gateway.hello?.withheldScopes.isEmpty == true, "nothing withheld after the upgrade")
    gateway.stop()
}

@MainActor
func runLive(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    // What launch does: the scene turning active asks for a reconnect mid-handshake.
    // Deliberate race delay (RACE_MS), not a wait on a condition.
    try? await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["RACE_MS"] ?? "30") ?? 30))
    gateway.reconnectIfNeeded()

    var sawPairing = false
    var sawReconnecting = false
    let connected = await waitFor("connection", timeout: 25) {
        if case .awaitingPairing = gateway.state { sawPairing = true }
        if case .reconnecting = gateway.state { sawReconnecting = true }
        return gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "connected and bootstrapped (pairing seen: \(sawPairing))")
    check(!sawReconnecting, "first connect never reports reconnecting")
    guard connected else { return }
    await runLiveShare(profile: profile, gateway: gateway)
    check(gateway.agents.count >= 3, "agents.list (\(gateway.agents.map(\.name)))")
    check(gateway.sessions.count >= 5, "sessions.subscribe (\(gateway.sessions.count) rows)")
    let sections = gateway.sections()
    check(sections.contains { $0.channels.contains { !$0.threads.isEmpty } }, "subagent session nested as thread")
    gateway.organization = .group
    check(gateway.sections().contains { $0.title == "Home" }, "group organization")
    gateway.organization = .agent

    let key = "agent:main:main"
    await gateway.loadCommands(sessionKey: key, agentId: "main")
    let liveCommands = gateway.slashCommands(for: key)
    check(liveCommands.contains { $0.name == "weather" && $0.source == "plugin" } && !liveCommands.contains { $0.name == "pair" },
          "commands.list (\(liveCommands.map(\.name)))")
    check(liveCommands.first { $0.name == "verbose" }?.args.first?.choices.count == 3, "commands.list includes args")
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

    // A cold, unregistered probe pages the server independently of cached/resident UI chats.
    let trip = pagingProbe(gateway: gateway, key: "agent:main:dashboard:trip")
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
    await checkLiveMessageSearch(gateway)
    // Not before the paging checks: they must load the trip before the background prefetch caches all of it.
    await checkSidebarVisibility(gateway, automations: ["agent:main:cron:morning-briefing", "agent:main:cron:disk-check"],
                                 slashKey: "agent:main:discord:slash:418235907214753792", label: "live")

    let research = gateway.chat(for: "agent:research:main")
    await research.load()
    let recovered = await waitFor("full message") {
        research.items.contains { !$0.isCapped && $0.plainText.hasSuffix("END OF REPORT") }
    }
    check(recovered && !research.items.contains { $0.plainText.contains("...(truncated)...") },
          "capped message replaced via chat.message.get")
    await research.load(force: true)
    check(research.items.contains { $0.plainText.hasSuffix("END OF REPORT") }, "full copy survives a history reload")

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

    await chat.send("follow a plan \(sendNonce)")
    var sawProgress = false
    let planned = await waitFor("progress card to complete", timeout: 20) {
        if chat.progressCard?.currentStep?.status == .inProgress { sawProgress = true }
        return chat.progressCard?.isComplete == true && !chat.isRunning
    }
    check(sawProgress && planned, "progressCard.changed → live progress card")
    check(chat.progressCard?.steps.count == 3 && chat.progressCard?.markdown != nil, "card has steps and note")
    await chat.dismissProgressCard()
    check(chat.progressCard == nil, "progressCard.put dismisses a finished card")
    await chat.load(force: true)
    let stayedDismissed = await waitFor("card read after reload", timeout: 2) { chat.progressCard != nil }
    check(!stayedDismissed, "dismissed card stays gone after reload")

    await gateway.patch(key, ["pinned": true])
    let pinned = await waitFor("pin") { gateway.sessions[key]?.isPinned == true }
    check(pinned, "sessions.patch round-trips via sessions.changed")

    // Model picker: the catalog loads, a new model applies to new replies, older ones keep theirs.
    await gateway.loadModels(agentId: "main")
    check(gateway.modelCatalogs["main"]?.contains { $0.ref == "openai/gpt-5.6-sol" } == true, "models.list catalog")
    check(gateway.defaultModelRef == "anthropic/claude-opus-4-8", "default model from sessions.list")
    func lastTurn() -> AssistantTurn? {
        for entry in chat.entries.reversed() {
            if case let .assistant(turn) = entry { return turn }
        }
        return nil
    }
    let previousModel = lastTurn()?.modelRef
    check(previousModel == "anthropic/claude-opus-4-8", "reply attributed to the model that wrote it (\(previousModel ?? "nil"))")
    let previousTurnId = lastTurn()?.id
    await gateway.setModel(key, to: "openai/gpt-5.6-sol")
    let switched = await waitFor("model switch") { gateway.sessions[key]?.modelRef == "openai/gpt-5.6-sol" }
    check(switched && gateway.sessions[key]?.modelOverrideSource == "user", "sessions.patch model round-trips")
    let beforeSwitchSend = chat.entries.count
    await chat.send("which model now?")
    let switchedReply = await waitFor("reply after switch", timeout: 20) {
        !chat.isRunning && chat.entries.count > beforeSwitchSend && lastTurn()?.isStreaming == false
    }
    check(switchedReply && lastTurn()?.modelRef == "openai/gpt-5.6-sol", "new reply uses the selected model")
    let oldTurn = chat.entries.lazy.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry, turn.id == previousTurnId { return turn }
        return nil
    }.first
    check(oldTurn?.modelRef == "anthropic/claude-opus-4-8", "earlier reply keeps its original model")
    await gateway.setModel(key, to: nil)
    let reset = await waitFor("model reset") {
        gateway.sessions[key]?.modelOverrideSource == nil && gateway.sessions[key]?.modelRef == "anthropic/claude-opus-4-8"
    }
    check(reset, "model reset to default")

    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval") { !gateway.approvals.isEmpty }
    check(approvalSeen, "exec approval surfaced")
    if let approval = gateway.approvals.first {
        await gateway.resolveApproval(approval, decision: "deny")
        check(gateway.approvals.isEmpty, "approval resolved")
    }

    _ = await waitFor("approval run to finish", timeout: 20) { !chat.isRunning }
    await checkApprovalOutcomes(gateway, chat: chat, label: "live")
    await checkLiveApprovals(profile: profile, gateway: gateway, chat: chat)
    await chat.send("ask me something")
    let asked = await waitFor("question.requested") { !gateway.pendingQuestions(for: key).isEmpty }
    check(asked, "ask_user question surfaced over the wire")
    if let prompt = gateway.pendingQuestions(for: key).first {
        check(prompt.questions.first?.questionId == "discord_remove" && prompt.runId != nil, "question record fields")
        var draft = QuestionDraft()
        draft.setText("Only #gyms", for: prompt.questions[0])
        let error = await gateway.answerQuestion(prompt, answers: draft.answers(for: prompt) ?? [:])
        check(error == nil && gateway.questions.isEmpty, "question.resolve answered")
    }
    let answeredReply = await waitFor("answered reply", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last { return !chat.isRunning && turn.body.contains("Only #gyms") }
        return false
    }
    check(answeredReply, "agent continues with the typed answer")

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
        // By server: a grouped chat dropped on its home agent section leaves its group.
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
    // Its own defaults suite: parallel runs must not share this device's persisted preferences.
    let (otherDefaults, otherSuite) = scratchDefaults()
    defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
    let other = GatewayStore(profile: otherProfile, defaults: otherDefaults)
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
    // Characters stay in each Gateway's map; the Pixel/Plush style remains device-wide.
    gateway.setAvatarCreature(.cat, for: "main")
    gateway.setAvatarRenderStyle(.plush)
    let avatarSynced = await waitFor("avatar sync") {
        other.avatarChoices["main"] == "cat" && other.avatarChoices[AvatarPreferences.renderStyleEntry] == "plush"
    }
    check(avatarSynced && gateway.avatarCreature(for: "main") == .cat && other.avatarCreature(for: "main") == .cat
          && otherDefaults.object(forKey: AvatarPreferences.creatureKey(for: "main")) == nil
          && otherDefaults.string(forKey: AvatarPreferences.renderStyleKey) == "plush",
          "avatar character and style sync through users.prefs")
    other.setAvatarCreature(nil, for: "main")
    let avatarCleared = await waitFor("avatar clear") { gateway.avatarChoices["main"] == nil }
    check(avatarCleared && gateway.avatarCreature(for: "main") == nil && other.avatarCreature(for: "main") == nil
          && otherDefaults.object(forKey: AvatarPreferences.creatureKey(for: "main")) == nil,
          "setting a character back to Auto syncs")
    gateway.setAvatarRenderStyle(.pixel)
    _ = await waitFor("avatar style reset") { other.avatarChoices[AvatarPreferences.renderStyleEntry] == "pixel" }
    UserDefaults.standard.removeObject(forKey: AvatarPreferences.renderStyleKey)

    // Groups: created empty, kept when emptied, reordered, and chats arranged by hand.
    do {
        let savedOrganization = gateway.organization
        gateway.organization = .group
        other.organization = .group
        func groupSection(_ store: GatewayStore, _ name: String) -> SidebarSection? {
            store.sections().first { $0.kind == .group(name) }
        }
        let created = await gateway.createGroup("Empty")
        check(created && groupSection(gateway, "Empty")?.channels.isEmpty == true, "empty group created")
        let duplicate = await gateway.createGroup("Empty")
        check(!duplicate, "duplicate group name rejected")
        let seen = await waitFor("empty group on other device") { other.groupNames.contains("Empty") }
        check(seen && groupSection(other, "Empty") != nil, "empty group shows on other devices")
        check(gateway.sections(search: "zzz-no-match").allSatisfy { $0.kind != .group("Empty") }, "empty group hidden while searching")

        await gateway.moveGroup("Empty", before: gateway.groupNames.first)
        check(gateway.groupNames.first == "Empty", "group moved to the top (\(gateway.groupNames))")
        let reordered = await waitFor("group order sync") { other.groupNames.first == "Empty" }
        check(reordered, "group order syncs")
        await gateway.moveGroup("Empty", before: nil)
        check(gateway.groupNames.last == "Empty", "group moved to the end (\(gateway.groupNames))")

        let personal = gateway.groupOrder("Personal")
        if let only = personal.first {
            await gateway.moveChat(only, toGroup: "Empty", before: nil)
            let moved = await waitFor("chat into Empty") { gateway.sessions[only]?.category == "Empty" }
            check(moved, "chat moved into a new group")
            let emptied = await waitFor("Personal emptied") { gateway.groupOrder("Personal").isEmpty }
            check(emptied && groupSection(gateway, "Personal") != nil && gateway.groupNames.contains("Personal"),
                  "group stays after its last chat leaves")
            await gateway.moveChat(only, toGroup: "Personal", before: nil)
            _ = await waitFor("chat back") { gateway.sessions[only]?.category == "Personal" }
        }

        // Arrange chats within a group by hand.
        // Sidebar-listed chats only: automations and slash commands are hidden by default (#174).
        let workKeys = gateway.sessions.values.filter { !$0.isSubagent && !$0.isArchived && !gateway.isHiddenInSidebar($0) }
            .map(\.key).sorted().prefix(3)
        for key in workKeys where gateway.sessions[key]?.category != "Work" {
            await gateway.moveChat(key, toGroup: "Work", before: nil)
        }
        let filled = await waitFor("work filled") { workKeys.allSatisfy { gateway.sessions[$0]?.category == "Work" } }
        check(filled, "chats moved into a group")
        let work = gateway.groupOrder("Work")
        if work.count >= 2, let last = work.last {
            await gateway.moveChat(last, toGroup: "Work", before: work.first)
            check(gateway.groupOrder("Work").first == last, "chat moved to the top of its group")
            check(groupSection(gateway, "Work")?.channels.first?.id == last, "sidebar shows the new chat order")
            let orderSynced = await waitFor("chat order sync") { other.groupOrder("Work").first == last }
            check(orderSynced, "chat order syncs through users.prefs")
            await gateway.moveChat(last, toGroup: "Work", before: nil)
            check(gateway.groupOrder("Work").last == last, "chat moved to the end of its group")
        }

        gateway.setGroupIcon("star.fill", for: "Empty")
        let iconSynced = await waitFor("group icon sync") { other.groupIcon(for: "Empty") == "star.fill" }
        check(iconSynced, "group icon syncs through users.prefs")
        await gateway.renameGroup("Empty", to: "Renamed")
        let renamed = await waitFor("rename group") { gateway.groupNames.contains("Renamed") && !gateway.groupNames.contains("Empty") }
        check(renamed, "empty group renamed")
        check(gateway.groupIcon(for: "Renamed") == "star.fill" && gateway.groupIcon(for: "Empty") == nil, "group icon follows a rename")
        let members = gateway.groupOrder("Work")
        await gateway.deleteGroup("Work")
        let deleted = await waitFor("delete group") {
            !gateway.groupNames.contains("Work") && members.allSatisfy { gateway.sessions[$0]?.category == nil }
        }
        check(deleted && members.allSatisfy { gateway.sessions[$0] != nil }, "deleting a group ungroups its chats")
        let deletedOther = await waitFor("delete sync") { !other.groupNames.contains("Work") }
        check(deletedOther, "group deletion syncs")
        await gateway.deleteGroup("Renamed")
        check(gateway.groupIcon(for: "Renamed") == nil, "deleting a group clears its icon")
        gateway.organization = savedOrganization
    }
    other.stop()

    // Approval History against the mock's 60 seeded decisions (30 exec, 18 plugin, 12 system-agent),
    // plus any approvals resolved earlier in this run.
    let history = gateway.approvalHistory
    check(gateway.hello?.methods.contains("approval.history") == true, "hello advertises approval.history")
    await history.load()
    check(history.supported && history.loadState == .idle && history.items.count == 50 && history.hasMore, "approval.history page 1 (\(history.items.count))")
    await history.loadMore()
    let seededIds = history.items.map(\.id).filter { $0.contains("_hist_") }
    let resolvedHere = history.items.filter { !$0.id.contains("_hist_") }
    check(seededIds.count == 60 && history.items.count == 60 + resolvedHere.count && Set(history.items.map(\.id)).count == history.items.count
          && !history.hasMore, "two pages = 60 seeded + \(resolvedHere.count) resolved, no duplicates")
    check(!resolvedHere.isEmpty && history.items.first?.id == resolvedHere.first?.id && resolvedHere.first?.status == .denied
          && resolvedHere.first.map(history.decidedBy) == "This device", "approval denied earlier is first, decided by this device")
    check(history.items.allSatisfy { $0.status != .pending } && Set(history.items.map(\.status)) == [.allowed, .denied, .expired, .cancelled],
          "terminal statuses only")
    for (filter, seeded) in [(ApprovalHistoryModel.KindFilter.exec, 30), (.plugin, 18), (.systemAgent, 12)] {
        await history.setKindFilter(filter)
        while history.hasMore { await history.loadMore() }
        let expected = seeded + (filter == .exec ? resolvedHere.count : 0)
        check(history.items.count == expected && history.items.allSatisfy { $0.kind.rawValue == filter.rawValue },
              "\(filter.label) filter (\(history.items.count)/\(expected))")
    }
    await history.setKindFilter(.all)
    await history.loadDetail("plugin_hist_001")
    check(history.details["plugin_hist_001"]?.kind == .plugin && history.details["plugin_hist_001"]?.title != nil
          && history.detailState["plugin_hist_001"] == .idle, "approval.get plugin_hist_001")
    await history.loadDetail("sys_hist_001")
    check(history.details["sys_hist_001"]?.kind == .systemAgent, "approval.get sys_hist_001")
    await history.loadDetail("nope_missing")
    check(history.detailState["nope_missing"]?.error == "This approval is no longer on the Gateway.", "approval.get not found")

    await checkUsageLive(gateway)
    // Pairing Requests: Pincer doesn't ask for operator.pairing, so standard access can't list.
    let standardPairing = gateway.pairingInbox
    check(gateway.hello?.methods.contains("channels.pairing.list") == true && standardPairing.supported, "hello advertises channels.pairing.list")
    check(!GatewayConnection.scopes.contains(PairingInboxModel.pairingScope) && !profile.requestedScopes.contains(PairingInboxModel.pairingScope),
          "operator.pairing is never requested")
    await standardPairing.seed()
    await standardPairing.load()
    check(!standardPairing.canManage && standardPairing.needsAccess && standardPairing.requests.isEmpty
          && standardPairing.loadState == .idle && standardPairing.pendingCount() == 0, "standard access → Full Management needed, no list")

    // Automations: read-only without admin, then run, pause, edit, create and delete.
    let automations = gateway.automations
    await automations.load()
    check(automations.supported && automations.jobs.count == 3 && automations.scheduler?.enabled == true,
          "cron.list + cron.status (\(automations.jobs.map(\.id)))")
    check(automations.jobs.last?.id == "paper-digest" && automations.jobs.last?.health == .paused, "paused jobs listed last")
    await automations.loadRuns(for: "disk-check")
    check(automations.runs["disk-check"]?.first?.status == .error
          && automations.runs["disk-check"]?.first?.sessionKey == "agent:main:cron:disk-check", "cron.runs history with chat link")
    check(!automations.canEdit, "automation writes need admin")
    if let disk = automations.job("disk-check") {
        let denied = await automations.runNow(disk)
        check(!denied && automations.operation(for: "disk-check").error?.contains("Full Management") == true, "run denied without admin")
    }
    // Gateway settings: read-only without admin, then edits through config.patch and plugins.*.
    let settings = gateway.settings
    await settings.load()
    check(settings.hasLoaded && settings.snapshot?.isValid == true && settings.schema != nil, "config.get + config.schema loaded")
    check(settings.value(at: ["gateway", "auth", "token"])?.isRedacted == true, "secrets arrive redacted")
    let weatherKeySet = settings.value(at: ["plugins", "entries", "weather", "config", "apiKey"]) != nil
    check(settings.plugins.contains { $0.id == "weather" && $0.needsSetup != weatherKeySet }, "plugins.list (\(settings.plugins.map(\.id)))")
    check(!settings.canEdit, "no admin scope by default")
    settings.set(["agents", "defaults", "timeoutSeconds"], 30)
    let readOnly = await settings.save()
    check(!readOnly && settings.saveState.error?.contains("Full Management") == true && settings.hasChanges, "writes need admin access, draft kept")
    settings.discardChanges()

    // Context meter: row snapshot vs limits, and "Compact now" through `/compact` without admin.
    let papersUsage = gateway.contextUsage(for: "agent:research:dashboard:papers")
    check(papersUsage == ContextUsage(used: 96_000, limit: 200_000) && papersUsage?.level == .normal,
          "context usage from the session row (\(papersUsage?.summary ?? "none"))")
    check(gateway.contextUsage(for: "agent:coder:main")?.level == .critical, "nearly full session is critical")
    let researchKey = "agent:research:main"
    check(gateway.defaultContextTokens == 128_000 && gateway.contextUsage(for: researchKey)?.limit == 128_000,
          "sessions.list defaults.contextTokens before the catalog loads")
    check(gateway.needsModelCatalogForContext(researchKey) || gateway.modelCatalogs["research"] != nil, "catalog needed for the limit")
    await gateway.loadModels(agentId: "research")
    check(!gateway.needsModelCatalogForContext(researchKey) && gateway.contextUsage(for: researchKey)?.limit == 200_000,
          "models.list includeDetails contextTokens used as the limit (\(gateway.contextUsage(for: researchKey)?.summary ?? "none"))")
    check(!gateway.canCompactDirectly, "sessions.compact needs admin")
    let coder = gateway.chat(for: "agent:coder:main")
    await coder.load()
    await coder.compact(instructions: "keep the build notes")
    check(coder.compaction?.isRunning == true || coder.compaction != nil, "compaction started")
    let coderCompacted = await waitFor("/compact", timeout: 20) {
        if case .finished = coder.compaction { return !coder.isRunning }
        return false
    }
    check(coderCompacted && coder.compaction == .finished(before: 190_000, after: 34_200),
          "/compact with instructions reports before → after (\(String(describing: coder.compaction)))")
    check(gateway.contextUsage(for: "agent:coder:main")?.used == 34_200, "meter drops after compaction")
    let sawMarker = await waitFor("compaction marker") {
        coder.items.contains { $0.markerKind == "compaction" }
    }
    check(sawMarker, "compaction marker in the transcript")
    coder.clearCompaction()
    check(coder.compaction == nil, "result cleared when the popover closes")
    await checkPushLive(gateway)
    await runLiveIntents(profile: profile, gateway: gateway)
    gateway.stop()

    let adminProfile = GatewayProfile(id: profile.id, name: "Mock", url: url, authMode: .token, access: .admin)
    check(adminProfile.requestedScopes.contains("operator.admin") && !profile.requestedScopes.contains("operator.admin"),
          "admin scope only when opted in")
    let decodedProfile = try? JSONDecoder().decode(GatewayProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","url":"ws://127.0.0.1","authMode":"token"}"#.utf8))
    check(decodedProfile?.access == .standard, "profiles saved before settings support still load")
    let legacyAdmin = try? JSONDecoder().decode(GatewayProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","url":"ws://127.0.0.1","authMode":"token","manageSettings":true}"#.utf8))
    check(legacyAdmin?.access == .admin, "legacy manageSettings → Full Management")
    let reencoded = try? JSONDecoder().decode(GatewayProfile.self, from: JSONEncoder().encode(adminProfile))
    check(reencoded?.access == .admin, "access level round-trips")
    let admin = GatewayStore(profile: adminProfile)
    admin.start()
    let adminConnected = await waitFor("admin connection") { admin.state.isConnected && admin.hello != nil }
    check(adminConnected && admin.settings.canEdit, "admin scope granted")
    let adminAutomations = admin.automations
    await adminAutomations.load()
    check(adminAutomations.canEdit, "admin can edit automations")
    var newJob = CronJobDraft(agentId: "main")
    newJob.name = "Live check"
    newJob.message = "Say hello"
    let createdId = await adminAutomations.save(newJob)
    check(createdId != nil && adminAutomations.job(createdId)?.nextRunAt != nil, "cron.add")
    if let createdId, let created = adminAutomations.job(createdId) {
        await adminAutomations.setEnabled(created, false)
        check(adminAutomations.job(createdId)?.health == .paused, "pause")
        var edit = CronJobDraft(job: adminAutomations.job(createdId)!, defaultAgentId: "main")
        edit.name = "Live check (edited)"
        edit.enabled = true
        let edited = await adminAutomations.save(edit)
        check(edited == createdId && adminAutomations.job(createdId)?.name == "Live check (edited)"
              && adminAutomations.job(createdId)?.enabled == true, "cron.update")
        // A stale revision is refused, then the latest job is loaded.
        let stale = await adminAutomations.save({ var d = edit; d.name = "Stale"; return d }())
        check(stale == nil && adminAutomations.operation(for: createdId).error?.contains("changed on the Gateway") == true,
              "stale edit refused")
        await adminAutomations.runNow(adminAutomations.job(createdId)!)
        let finished = await waitFor("cron run") {
            adminAutomations.runs[createdId]?.first?.status == .ok && adminAutomations.job(createdId)?.health == .ok
        }
        check(finished, "run now → cron event → history (\(adminAutomations.runs[createdId]?.count ?? 0) runs)")
        let runKey = adminAutomations.runs[createdId]?.first?.sessionKey
        check(runKey == "agent:main:cron:\(createdId)", "run links to its chat")
        await adminAutomations.remove(adminAutomations.job(createdId)!)
        check(adminAutomations.job(createdId) == nil, "cron.remove")
    }
    let adminSettings = admin.settings
    await adminSettings.load()
    let hashBefore = adminSettings.snapshot?.hash
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 30)
    check(adminSettings.changeCount == 1 && adminSettings.saveBlocker == nil, "one pending change")
    let hot = await adminSettings.save()
    check(hot && adminSettings.lastSave?.outcome == .applied && !adminSettings.hasChanges,
          "config.patch hot-applied (\(adminSettings.saveState.error ?? "")\(adminSettings.writeIssues.map(\.message)))")
    check(adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 30 && adminSettings.snapshot?.hash != hashBefore,
          "saved value re-read with a new hash")
    let bindValue: JSONValue = adminSettings.value(at: ["gateway", "bind"]) == "lan" ? "tailnet" : "lan"
    adminSettings.set(["gateway", "bind"], bindValue)
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 35)
    let restarting = await adminSettings.save()
    check(restarting && adminSettings.lastSave?.outcome == .restarting
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 35, "several changes in one save; restart reported")
    adminSettings.set(["gateway", "port"], 70000)
    check(adminSettings.saveBlocker == nil || adminSettings.validationProblems["gateway.port"] != nil, "local validation when the schema has bounds")
    if adminSettings.saveBlocker == nil {
        let invalid = await adminSettings.save()
        check(!invalid && adminSettings.writeIssues.first?.path == "gateway.port" && adminSettings.hasChanges,
              "invalid value rejected with its path, draft kept")
        check(!adminSettings.issues(under: ["gateway"]).isEmpty && adminSettings.issues(under: ["agents"]).isEmpty, "issues matched to their section")
    }
    adminSettings.discardChanges()
    check(adminSettings.writeIssues.isEmpty && !adminSettings.hasChanges, "discard clears the draft and issues")
    adminSettings.set(["channels", "discord", "dmPolicy"], "allowlist")
    let keptSecret = await adminSettings.save()
    check(keptSecret && adminSettings.value(at: ["channels", "discord", "dmPolicy"]) == "allowlist"
          && adminSettings.value(at: ["channels", "discord", "token"])?.isRedacted != false, "redacted secret round-trips")
    adminSettings.set(["tools", "allow"], json(#"["exec"]"#))
    let lists = await adminSettings.save()
    check(lists && adminSettings.value(at: ["tools", "allow"]) == json(#"["exec"]"#), "lists replace with replacePaths")

    // Another writer changed the config: unrelated edits are rebased and saved, clashing ones asked about.
    let otherAdminProfile = GatewayProfile(name: "Other admin", url: url, authMode: .token, access: .admin)
    otherAdminProfile.secret = token
    let other2 = GatewayStore(profile: otherAdminProfile)
    other2.start()
    _ = await waitFor("other admin") { other2.state.isConnected && other2.hello != nil }
    await other2.settings.load()
    other2.settings.set(["agents", "defaults", "timeoutSeconds"], 45)
    await other2.settings.save()
    let rebasedModel = JSONValue.string("mock/rebased-\(UUID().uuidString.prefix(6))")
    adminSettings.set(["agents", "defaults", "model"], rebasedModel)
    let rebasedSave = await adminSettings.save()
    check(rebasedSave && adminSettings.value(at: ["agents", "defaults", "model"]) == rebasedModel
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 45, "stale hash → rebased and saved without clobbering")
    other2.settings.set(["agents", "defaults", "timeoutSeconds"], 50)
    await other2.settings.load()
    await other2.settings.save()
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 60)
    let clash = await adminSettings.save()
    check(!clash && adminSettings.conflicts.first?.id == "agents.defaults.timeoutSeconds"
          && adminSettings.conflicts.first?.theirs == 50, "clashing edit becomes a conflict (\(adminSettings.saveState.error ?? ""))")
    if let conflict = adminSettings.conflicts.first { adminSettings.resolve(conflict, keepMine: false) }
    check(adminSettings.conflicts.isEmpty && !adminSettings.hasChanges
          && adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 50, "use the Gateway's value")
    other2.stop()

    if let weather = adminSettings.plugin("weather") {
        await adminSettings.loadCredentials(for: weather)
        check(adminSettings.credentials["weather"]?.first?.path.last == "apiKey", "plugins.inspect credentials")
        adminSettings.set(weather.configPath + ["apiKey"], "short")
        let short = await adminSettings.save()
        let apiKeyId = "plugins.entries.weather.config.apiKey"
        check(!short && (adminSettings.validationProblems[apiKeyId] != nil || adminSettings.writeIssues.first?.path == apiKeyId),
              "plugin config validated")
        adminSettings.set(weather.configPath + ["apiKey"], "weather-key-123")
        await adminSettings.save()
        check(adminSettings.plugin("weather")?.needsSetup == false && adminSettings.value(at: weather.configPath + ["apiKey"])?.isRedacted == true,
              "plugin set up with its credential")
    }
    if let browser = adminSettings.plugin("browser") {
        await adminSettings.setEnabled(browser, true)
        check(adminSettings.pendingConfirmation != nil && adminSettings.plugin("browser")?.enabled == false, "capability consent asked first")
        if let confirmation = adminSettings.pendingConfirmation { await adminSettings.confirm(confirmation) }
        check(adminSettings.plugin("browser")?.enabled == true && adminSettings.pendingConfirmation == nil, "plugin enabled after consent")
        await adminSettings.setEnabled(adminSettings.plugin("browser")!, false)
        check(adminSettings.plugin("browser")?.enabled == false, "plugin disabled")
    }
    adminSettings.set(["agents", "defaults", "timeoutSeconds"], 55)
    let installed = await adminSettings.install(from: .npm, spec: "openclaw-plugin-todo@1.0.0")
    check(installed && adminSettings.plugin("todo")?.enabled == true, "plugins.install")
    check(adminSettings.value(at: ["agents", "defaults", "timeoutSeconds"]) == 55, "plugin changes keep the unsaved draft")
    adminSettings.discardChanges()
    let unverified = await adminSettings.install(from: .clawhub, spec: "@someone/unverified-thing")
    check(!unverified, "unverified install waits for confirmation")
    if let confirmation = adminSettings.pendingConfirmation { await adminSettings.confirm(confirmation) }
    check(adminSettings.plugin("unverified-thing") != nil, "install after acknowledging the policy warning")
    if let todo = adminSettings.plugin("todo") {
        await adminSettings.uninstall(todo)
        check(adminSettings.plugin("todo") == nil, "plugins.uninstall")
    }
    let missing = await adminSettings.install(from: .npm, spec: "missing-package")
    check(!missing && adminSettings.operation(for: GatewaySettingsModel.installKey).error?.contains("not found") == true,
          "install errors surface")
    // Pairing Requests with Full Management against the mock's three seeded senders.
    let pairing = admin.pairingInbox
    await pairing.seed()
    check(pairing.canManage && !pairing.needsAccess && pairing.loadState == .idle && pairing.accounts.count == 2
          && pairing.requests.map(\.requestId) == ["pr_maya", "pr_discord", "pr_soon"], "channels.pairing.list (\(pairing.requests.map(\.requestId)))")
    check(pairing.pendingCount() == 3 && pairing.limits?.ttl == 3600 && pairing.limits?.pendingPerAccount == 3 && !pairing.canBootstrapCommandOwner,
          "badge count and limits")
    if let maya = pairing.requests.first(where: { $0.requestId == "pr_maya" }),
       let discord = pairing.requests.first(where: { $0.requestId == "pr_discord" })
    {
        check(maya.title == "Maya Chen" && maya.senderLine == "Telegram user id: 5550142" && maya.accountLine == "Telegram · Home bot"
              && maya.details.map(\.label) == ["Language code"] && maya.showsLastSeen, "mock request presentation")
        check(discord.title == "418820017734812160" && !discord.notifySupported, "sender with only an id")
        let approved = await pairing.approve(maya, notify: true)
        check(approved && pairing.notice == nil && pairing.operation(for: maya) == .idle, "channels.pairing.approve")
        let dismissed = await pairing.dismiss(discord)
        check(dismissed && pairing.requests.map(\.requestId) == ["pr_soon"] && pairing.pendingCount() == 1, "channels.pairing.dismiss")
        await pairing.dismiss(discord)
        check(pairing.notice?.text == PairingInboxModel.staleMessage && pairing.requests.map(\.requestId) == ["pr_soon"],
              "stale request → already handled notice and refresh")
        await pairing.refresh()
        check(pairing.requests.map(\.requestId) == ["pr_soon"] && pairing.loadState == .idle, "refresh after actions")
    } else {
        check(false, "mock seeded Maya and a Discord sender")
    }
    check(admin.canCompactDirectly, "admin compacts through sessions.compact")
    let papers = admin.chat(for: "agent:research:dashboard:papers")
    await papers.load()
    await papers.compact()
    check(papers.compaction == .finished(before: 96_000, after: 17_280),
          "sessions.compact reports tokensBefore → tokensAfter (\(String(describing: papers.compaction)))")
    let papersDropped = await waitFor("papers row") { admin.contextUsage(for: "agent:research:dashboard:papers")?.used == 17_280 }
    check(papersDropped, "session row updated after sessions.compact")
    await papers.compact()
    await papers.compact()
    if case let .skipped(reason) = papers.compaction {
        check(reason.contains("Nothing to compact"), "nothing left to compact is reported, not an error")
    } else {
        check(false, "nothing left to compact (\(String(describing: papers.compaction)))")
    }
    await runLiveExecPolicy(profile: profile, gateway: gateway, admin: admin)
    await runLiveAgents(profile: profile, gateway: gateway, admin: admin)
    await runLiveSubagents(gateway: admin)
    // Before Health: reconnects the mock's degraded Telegram so only the failed delivery is left.
    await runLiveChannels(profile: profile, admin: admin)
    await runLiveDevices(profile: profile, gateway: gateway, admin: admin)
    await runLiveSkills(profile: profile, admin: admin)
    await runMessageEditChecks(admin, admin: true, "live")
    await runLiveSessions(profile: profile, admin: admin)

    // Gateway Logs after Pairing Requests, whose seeded request expires minutes after the mock starts.
    await checkGatewayLogsLive(admin)
    // Health and a safe restart. Last, since a restart drops every client.
    let health = admin.health
    await health.load()
    let deliveryId = "queue:outbound-prepared-v1"
    check(health.hasLoaded && health.level == .degraded && health.activeIssues.map(\.id) == [deliveryId]
          && health.health?.channels.first?.id == "discord", "health loads, degraded by the mock's failed delivery (\(health.issues.map(\.title)))")
    // Dismissing on one device hides it on another device of the same user, through users.prefs.
    let secondProfile = GatewayProfile(name: "Mock health", url: url, authMode: .token)
    secondProfile.secret = token
    let second = GatewayStore(profile: secondProfile)
    second.start()
    let secondReady = await waitFor("second health device") { second.state.isConnected && !second.sessions.isEmpty }
    await second.health.load()
    if secondReady, let delivery = health.activeIssues.first(where: { $0.id == deliveryId }) {
        check(!delivery.canAlwaysIgnore && delivery.fingerprint == "count=1", "failed deliveries dismiss until the count goes up")
        let prefsSynced = await waitFor("health dismissals first sync") {
            UserDefaults.standard.bool(forKey: "pincer.healthDismissalsSynced.\(admin.id.uuidString)")
                && UserDefaults.standard.bool(forKey: "pincer.healthDismissalsSynced.\(second.id.uuidString)")
        }
        check(prefsSynced, "health dismissals pulled on both devices")
        health.dismiss(delivery)
        check(health.level == .healthy && health.indicator == nil, "dismissed delivery doesn't count")
        let dismissedElsewhere = await waitFor("dismissal sync") { second.health.level == .healthy }
        check(dismissedElsewhere && second.health.dismissedIssues.map(\.id) == [deliveryId]
              && second.healthDismissals[deliveryId] == "until:count=1", "dismissal syncs to the other device")
        second.health.restore(id: deliveryId)
        let restored = await waitFor("restore sync") { health.level == .degraded }
        check(restored && admin.healthDismissals.isEmpty, "restore syncs back")
    } else {
        check(false, "second device and the mock's failed delivery issue")
    }
    second.stop()
    for prefix in ["serverNames", "serverNamesSynced", "chatIcons", "chatIconsSynced", "avatars", "avatarsSynced", "healthDismissals",
                   "healthDismissalsSynced"] {
        UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(second.id.uuidString)")
    }
    check(health.heartbeat?.status == .okToken && health.presence.contains(where: health.isThisDevice), "heartbeat and this device's presence")
    check((health.uptime() ?? 0) > 3600, "uptime from the hello snapshot")
    check(!gateway.health.canRestart && admin.health.canRestart, "restart needs admin")
    let uptimeBefore = health.uptime() ?? 0
    await gateway.health.restart()
    // Negative window: a non-admin restart must not disturb the connections.
    try? await Task.sleep(for: .milliseconds(400))
    check(gateway.health.restartState == .failed(ConfigWriteError.adminRequired.message) && gateway.state.isConnected
          && admin.state.isConnected && (health.uptime() ?? 0) >= uptimeBefore,
          "non-admin restart sends nothing and the Gateway stays up (\(gateway.health.restartState))")
    gateway.health.dismissRestartStatus()
    await health.restart()
    check(health.restartState == .scheduled(coalesced: false), "restart scheduled (\(health.restartState))")
    let restarted = await waitFor("gateway restart", timeout: 30) {
        if case .restarted = health.restartState { return admin.state.isConnected }
        return false
    }
    check(restarted && (health.uptime() ?? .infinity) < 60, "reconnected after restart with a fresh uptime (\(health.restartState))")
    let othersBack = await waitFor("clients back after restart", timeout: 30) { gateway.state.isConnected && other.state.isConnected }
    check(othersBack, "other clients reconnect after the restart")
    admin.stop()

    for store in [gateway, other] {
        for prefix in ["serverNames", "serverNamesSynced", "chatIcons", "chatIconsSynced", "avatars", "avatarsSynced", "healthDismissals",
                           "healthDismissalsSynced"] {
            UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(store.id.uuidString)")
        }
    }
    gateway.stop()
}
