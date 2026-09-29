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

@MainActor
func runDemo() async {
    // Keep "approve later" quick; the demo reads this when it schedules the approval.
    setenv("PINCER_DEMO_LATER_APPROVAL_MS", "500", 1)
    let profile = GatewayProfile.demo()
    check(profile.isDemo && profile.authMode == .none, "demo profile")
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo connection") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo connected and bootstrapped")
    guard connected else { return }
    _ = gateway.chat(for: "agent:main:dashboard:trip")
    check(gateway.agents.count >= 3, "agents (\(gateway.agents.map(\.name)))")
    check(gateway.sessions.count >= 5, "sessions (\(gateway.sessions.count))")
    check(gateway.approvals.map(\.id) == ["approval_demo_push"] && gateway.approvals.first?.isExpired() == false
          && gateway.approvals.first?.command == "git push origin fix/login-timeout", "demo opens with one pending approval")
    check(gateway.totalUnread >= 3, "demo opens with unread chats (\(gateway.totalUnread))")

    let key = "agent:main:main"
    await gateway.loadCommands(sessionKey: key, agentId: "main")
    let demoCommands = gateway.slashCommands(for: key)
    check(demoCommands.contains { $0.name == "restart" } && demoCommands.contains { $0.source == "skill" },
          "demo commands.list (\(demoCommands.count))")
    gateway.selectedKey = key
    let chat = gateway.chat(for: key)
    let loaded = await waitFor("history") { chat.hasLoaded }
    check(loaded && !chat.entries.isEmpty, "welcome history loaded")

    let trip = gateway.chat(for: "agent:main:dashboard:trip")
    // Background prefetch may already have cached trip's whole history (it skips chats open here
    // from now on): drop that so this checks paging from the Gateway.
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:trip")
    await trip.load()
    check(trip.hasMoreHistory && trip.items.count == 120, "trip latest page (\(trip.items.count))")
    // Find in Chat only searches what's loaded, so the latest page must have something to find.
    for word in ["onsen", "Kyoto", "ramen"] {
        let found = TranscriptSearch.matches(word, in: trip.entries)
        check(found.count >= 3, "Find in Chat finds \"\(word)\" in the trip's latest page (\(found.count))")
    }
    let latestRamen = trip.items.filter { $0.plainText.localizedCaseInsensitiveContains("ramen") }.count
    check(latestRamen * 2 <= trip.items.count, "trip isn't all ramen on the latest page (\(latestRamen)/\(trip.items.count))")
    await trip.loadOlder()
    await trip.loadOlder()
    check(!trip.hasMoreHistory && trip.items.count == 302, "trip paged to start (\(trip.items.count))")
    await checkDemoMessageSearch(gateway, trip: trip)
    await checkDemoSeededSearchTerms(gateway, trip: trip)
    await checkExportAndBookmarks(gateway)
    let allRamen = trip.items.filter { $0.plainText.localizedCaseInsensitiveContains("ramen") }.count
    check(allRamen * 2 <= trip.items.count, "trip transcript is varied (ramen in \(allRamen)/\(trip.items.count))")
    let tripUsage = gateway.contextUsage(for: "agent:main:dashboard:trip")
    check(tripUsage?.used == 192_000 && tripUsage?.limit == 200_000 && tripUsage?.level == .critical,
          "trip context meter is critical (\(tripUsage?.summary ?? "none"))")
    // A ring filled to only ~12% is a short arc that reads as a stuck loading spinner (#280).
    for idle in ["agent:kiko:main", "agent:research:dashboard:papers"] {
        let idleUsage = gateway.contextUsage(for: idle)
        check(idleUsage != nil && idleUsage!.percent >= 25 && gateway.needsModelCatalogForContext(idle) == false,
              "idle demo chat \(idle) has a clearly partial context ring (\(idleUsage?.percentLabel ?? "none"))")
    }
    let mainUsage = gateway.contextUsage(for: "agent:main:main")
    check(mainUsage?.level == .warning, "Main context meter is a warning (\(mainUsage?.summary ?? "none"))")

    // Canned replies mustn't trip other trigger words by accident.
    let helloStart = chat.entries.count
    let approvalsBefore = gateway.approvals.count
    await chat.send("hello")
    let helloDone = await waitFor("hello reply", timeout: 20) { !chat.isRunning && chat.entries.count > helloStart + 1 }
    check(helloDone && gateway.pendingQuestions(for: key).isEmpty && gateway.approvals.count == approvalsBefore && chat.progressCard == nil,
          "a hello reply raises no question, approval or plan")
    if case let .assistant(turn)? = chat.entries.last {
        check(turn.body.contains("onsen") && turn.body.contains("⌘K") && turn.body.contains("/compact"), "hello reply lists things to try")
        // A tip read back as a message should trigger only what it describes (tool/disk/image match as substrings).
        func triggers(_ line: String) -> Set<String> {
            let lowered = line.lowercased()
            var found = Set<String>()
            if ["tool", "disk"].contains(where: lowered.contains) { found.insert("tool") }
            if lowered.contains("image") { found.insert("image") }
            for word in ["approve", "ask", "plan"] where lowered.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                found.insert(word)
            }
            return found
        }
        let crossed = turn.body.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") && triggers($0).count > 1 }
        check(crossed.isEmpty, "each tip triggers one thing (\(crossed))")
    }

    let before = chat.entries.count
    await chat.send("show me a tool and an image")
    var sawThinking = false
    var sawTool = false
    // Polls quickly so the streaming phases stay visible when CI shortens the demo's pacing.
    let finished = await waitFor("demo reply", timeout: 20, every: 10) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming {
            if !turn.thinking.isEmpty { sawThinking = true }
            if !turn.tools.isEmpty { sawTool = true }
        }
        return !chat.isRunning && chat.entries.count > before
    }
    check(finished, "demo reply finished")
    check(sawThinking && sawTool, "demo streamed thinking and a tool")
    if case let .assistant(turn)? = chat.entries.last, let image = turn.images.first {
        check(!turn.body.isEmpty, "demo reply has text")
        gateway.images.load(image, sessionKey: key)
        let decoded = await waitFor("chart") { gateway.images.cached(image) != nil }
        check(decoded, "demo chart decoded")
    } else {
        check(false, "demo reply carries a chart")
    }

    let longBefore = chat.entries.count
    await chat.send("long")
    var sawLiveStreaming = false
    let longDone = await waitFor("long reply", timeout: 30, every: 10) {
        if case let .assistant(turn)? = chat.entries.last, turn.id.hasPrefix("live-"), turn.isStreaming { sawLiveStreaming = true }
        return !chat.isRunning && chat.entries.count > longBefore
    }
    check(longDone, "long reply finished")
    check(sawLiveStreaming, "long reply streamed as a live entry")
    if case let .assistant(turn)? = chat.entries.last {
        check(turn.body.count > 3000 && turn.body.contains("## Building a quiet home lab")
              && turn.body.contains("```swift") && turn.body.contains("| Service | Host | Idle power |"),
              "long reply has heading, code fence and table (\(turn.body.count) chars)")
    } else {
        check(false, "long reply is an assistant turn")
    }

    await gateway.loadModels(agentId: "main")
    check(!(gateway.modelCatalogs["main"] ?? []).isEmpty, "demo model catalog")
    await gateway.setModel(key, to: "openai/gpt-5.6-sol")
    let switched = await waitFor("model switch") { gateway.sessions[key]?.modelRef == "openai/gpt-5.6-sol" }
    check(switched, "demo model switch")

    await gateway.automations.load()
    check(gateway.automations.hasLoaded && !gateway.automations.supported && gateway.automations.jobs.isEmpty,
          "gateway without cron.* shows automations unavailable")

    // Approval History: 12 seeded decisions (7 commands, 3 plugins, 2 system changes).
    let history = gateway.approvalHistory
    history.pageSize = 5
    await history.load()
    check(history.supported && history.hasLoaded && history.items.count == 5 && history.hasMore, "demo approval.history first page")
    await history.loadMore()
    await history.loadMore()
    let demoIds = history.items.map(\.id)
    check(demoIds.count == 12 && Set(demoIds).count == 12 && !history.hasMore, "demo history paged to the end, no duplicates (\(demoIds.count))")
    check(zip(history.items, history.items.dropFirst()).allSatisfy { ($0.resolvedAt ?? .distantPast) >= ($1.resolvedAt ?? .distantPast) },
          "demo history newest first")
    check(Set(history.items.map(\.status)) == [.allowed, .denied, .expired, .cancelled], "demo covers every terminal status")
    check(Set(history.items.map { history.decidedBy($0) }).isSuperset(of: ["This device", "OpenClaw (automatic)", "Unknown", "Runtime"])
          && history.items.contains { history.decidedBy($0).hasPrefix("Another device (") }
          && history.items.contains { history.decidedBy($0).hasPrefix("Channel") }, "demo resolvers in plain words")
    for (filter, count) in [(ApprovalHistoryModel.KindFilter.exec, 7), (.plugin, 3), (.systemAgent, 2)] {
        await history.setKindFilter(filter)
        while history.hasMore { await history.loadMore() }
        check(history.items.count == count && history.items.allSatisfy { $0.kind.rawValue == filter.rawValue },
              "demo \(filter.label) filter (\(history.items.count))")
    }
    await history.setKindFilter(.all)

    // Gateway Logs: the demo's simulated log file grows between polls.
    let demoLogs = gateway.gatewayLogs
    await demoLogs.poll()
    check(demoLogs.supported && demoLogs.failure == nil && demoLogs.lineCount > 100, "demo logs.tail first page (\(demoLogs.lineCount))")
    check(GatewayLogLevel.allCases.allSatisfy { demoLogs.count($0) > 0 } && demoLogs.entries.contains { $0.level == nil },
          "demo log covers every level plus plain text")
    check(demoLogs.file?.hasPrefix("/tmp/openclaw/openclaw-") == true && demoLogs.cursor == demoLogs.size, "demo log file and cursor")
    check(demoLogs.entries.contains { $0.message.hasPrefix("chat.send \(key)") }, "demo chat shows up in the log")
    check(demoLogs.entries.contains { $0.message.count > GatewayLogEntry.displayLimit && $0.displayMessage.count < $0.message.count },
          "demo long line capped for display")
    let demoCursor = demoLogs.cursor ?? 0
    let demoLast = demoLogs.entries.last?.id ?? 0
    // The demo emits log lines on its own clock; give it time to produce new ones.
    try? await Task.sleep(for: .milliseconds(700))
    await demoLogs.poll()
    let demoNew = demoLogs.entries.filter { $0.id > demoLast }
    check(!demoNew.isEmpty && (demoLogs.cursor ?? 0) > demoCursor && !demoNew.contains(where: \.isMarker),
          "demo log grows between polls (\(demoNew.count) new)")
    check(demoLogs.cursor == demoCursor + demoNew.reduce(0) { $0 + $1.raw.utf8.count + 1 },
          "demo cursor advances by the new lines' UTF-8 bytes")
    if let plugin = history.items.first(where: { $0.kind == .plugin }) {
        await history.loadDetail(plugin.id)
        check(history.details[plugin.id]?.detail != nil || history.record(plugin.id)?.title == plugin.title, "demo approval.get detail")
        check(history.detailState[plugin.id] == .idle && history.record(plugin.id)?.pluginId == plugin.pluginId, "demo detail round-trips")
    } else {
        check(false, "demo history has a plugin")
    }

    await checkUsageDemo(gateway)
    await history.loadMore()
    check(history.items.count == 10 && history.hasMore, "demo second page before resolving")

    let seededApprovals = Set(gateway.approvals.map(\.id))
    await chat.send("please approve this")
    let approvalSeen = await waitFor("approval") { gateway.approvals.contains { !seededApprovals.contains($0.id) } }
    check(approvalSeen, "demo approval surfaced")
    if let approval = gateway.approvals.first(where: { !seededApprovals.contains($0.id) }) {
        await history.loadDetail(approval.id)
        check(history.details[approval.id]?.status == .pending, "demo approval.get returns a pending approval")
        await gateway.resolveApproval(approval, decision: "allow-once")
        check(gateway.approvals.map(\.id) == Array(seededApprovals), "demo approval resolved, the seeded one still waits")
        let merged = await waitFor("history refresh after resolve", timeout: 5) { history.items.first?.id == approval.id }
        check(merged && history.items.count == 11, "resolved approval shows first after exec.approval.resolved (\(history.items.count))")
        if let top = history.items.first {
            check(top.statusLabel == "Allowed once" && history.decidedBy(top) == "This device" && top.sessionKey == key,
                  "resolved entry decided by this device in its chat")
        }
        await history.refresh()
        check(history.items.first?.id == approval.id && history.items.count == 5, "refresh keeps the resolved entry first")
    }
    history.pageSize = ApprovalHistoryModel.defaultPageSize

    let settled = await waitFor("approval run to finish", timeout: 20) { !chat.isRunning }
    check(settled, "demo approval run finished")
    await checkApprovalOutcomes(gateway, chat: chat, label: "demo")

    // "approve later" raises its approval a moment after the run, outside it (to answer from a notification).
    let knownApprovals = Set(gateway.approvals.map(\.id))
    await chat.send("approve later")
    var raisedDuringRun = false
    let laterRunDone = await waitFor("approve later run", timeout: 20) {
        if chat.isRunning && gateway.approvals.contains(where: { !knownApprovals.contains($0.id) }) { raisedDuringRun = true }
        return !chat.isRunning
    }
    check(laterRunDone && !raisedDuringRun && gateway.approvals.allSatisfy { knownApprovals.contains($0.id) },
          "approve later: no approval during the run")
    if case let .assistant(turn)? = chat.entries.last {
        check(turn.body.localizedCaseInsensitiveContains("few seconds"), "approve later: the reply says it's coming")
    }
    let laterSeen = await waitFor("later approval", timeout: 10) { gateway.approvals.contains { !knownApprovals.contains($0.id) } }
    check(laterSeen && !chat.isRunning, "approve later: approval arrives after the run finished")
    if let later = gateway.approvals.first(where: { !knownApprovals.contains($0.id) }) {
        check(later.allowsAlways && later.allowedDecisions?.count == 3 && later.sessionKey == key && later.agentId == "main"
              && later.command.contains("brew"), "approve later: full approval for this chat (\(later.command))")
        check((later.expiresAt?.timeIntervalSinceNow ?? 0) > 9 * 60, "approve later: expires in about 10 minutes")
        let outcome = await gateway.resolveApproval(later, decision: "allow-once")
        check(outcome == .resolved && !gateway.approvals.contains { $0.id == later.id }, "approve later: resolved (\(outcome))")
        await history.refresh()
        check(history.items.first?.id == later.id && history.items.first?.statusLabel == "Allowed once",
              "approve later: shows first in Approval History")
    } else {
        check(false, "approve later: approval surfaced")
    }

    await chat.send("ask me what to remove")
    let demoAsked = await waitFor("demo question") { !gateway.pendingQuestions(for: key).isEmpty }
    check(demoAsked, "demo ask_user question surfaced")
    if let prompt = gateway.pendingQuestions(for: key).first {
        check(prompt.questions.first?.options.count == 3 && prompt.questions.first?.allowsFreeText == true, "demo question has options and free text")
        check(gateway.pendingQuestions(for: "agent:main:elsewhere").isEmpty, "question stays in its own chat")
        let incomplete = await gateway.answerQuestion(prompt, answers: [:])
        check(incomplete != nil && !gateway.questions.isEmpty, "incomplete answers rejected and the card stays")
        var draft = QuestionDraft()
        draft.toggle(number: 3, in: prompt.questions[0])
        let error = await gateway.answerQuestion(prompt, answers: draft.answers(for: prompt) ?? [:])
        check(error == nil && gateway.questions.isEmpty, "demo question answered")
        let late = await gateway.skipQuestion(prompt)
        check(late == nil, "settling an already-answered question is quiet")
    }
    let demoAnswered = await waitFor("demo answer reply", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last { return !chat.isRunning && turn.body.contains("Stop watching Discord channels here") }
        return false
    }
    check(demoAnswered, "demo reply uses the answer")
    await chat.send("ask me again")
    let demoAskedAgain = await waitFor("second demo question") { !gateway.pendingQuestions(for: key).isEmpty }
    if demoAskedAgain, let prompt = gateway.pendingQuestions(for: key).first {
        let error = await gateway.skipQuestion(prompt)
        check(error == nil && gateway.questions.isEmpty, "demo question skipped")
    } else {
        check(false, "second demo question surfaced")
    }
    let demoSkipped = await waitFor("skip reply", timeout: 20) { !chat.isRunning }
    check(demoSkipped, "demo run finishes after a skip")
    await chat.send("follow a plan")
    let demoPlanned = await waitFor("demo progress card", timeout: 20) {
        chat.progressCard?.isComplete == true && !chat.isRunning
    }
    check(demoPlanned, "demo progress card walks its plan")

    let demoUsage = gateway.contextUsage(for: key)
    check(demoUsage != nil && demoUsage!.used >= 172_000 && demoUsage!.limit == 200_000, "demo context meter (\(demoUsage?.summary ?? "none"))")
    check(!gateway.canCompactDirectly, "demo compacts through /compact")
    await chat.compact()
    let demoCompacted = await waitFor("demo compaction", timeout: 20) {
        if case .finished = chat.compaction { return !chat.isRunning }
        return false
    }
    if case let .finished(before?, after?) = chat.compaction {
        check(demoCompacted && after < before && gateway.contextUsage(for: key)?.used == after,
              "demo compaction \(chat.compaction?.message ?? "")")
    } else {
        check(false, "demo compaction finished (\(String(describing: chat.compaction)))")
    }

    let newKey = await gateway.createSession(agentId: "research", label: "Demo check", category: "Work")
    check(newKey != nil && gateway.sessions[newKey ?? ""] != nil, "demo sessions.create")

    // Command palette over the demo's chats.
    let seededPins: Set<String> = ["agent:main:discord:channel:123", "agent:main:dashboard:trip", "agent:research:dashboard:papers"]
    func sidebarPins(_ keys: Set<String>) -> [String] {
        gateway.sections().flatMap { $0.channels.map(\.row.key) }.filter(keys.contains)
    }
    check(Set(gateway.pinnedChats.map(\.key)) == seededPins && gateway.pinnedChats.map(\.key) == sidebarPins(seededPins),
          "three pinned chats in sidebar order (\(gateway.pinnedChats.map(\.key)))")
    let coderKey = "agent:coder:main"
    await gateway.patch(coderKey, ["pinned": true])
    let pinnedCoder = await waitFor("pin") { gateway.pinnedChats.count == 4 }
    check(pinnedCoder && gateway.pinnedChats.map(\.key) == sidebarPins(seededPins.union([coderKey])), "⌘1–⌘9 follow the sidebar's order")
    let recentTarget = Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:research:dashboard:papers")
    let chatItems = CommandPalette.chatItems(gateways: [gateway], selectedGatewayId: gateway.id, recent: [recentTarget])
    check(chatItems.first?.action == .openChat(recentTarget), "recent chats listed first")
    check(!chatItems.contains { $0.id.contains(":subagent:") }, "subagent runs left out")
    check(Set(chatItems.map(\.id)).count == chatItems.count, "each chat listed once")
    let pinnedShortcuts = gateway.pinnedChats.map { pin in chatItems.first { $0.id.hasSuffix(":" + pin.key) }?.shortcut }
    check(pinnedShortcuts == ["⌘1", "⌘2", "⌘3", "⌘4"], "pinned chats show their shortcut (\(pinnedShortcuts))")
    check(chatItems.filter { $0.shortcut != nil }.count == 4, "only pinned chats have shortcuts")
    check(PaletteMatcher.rank(chatItems, query: "scout digest").first?.title == "Paper digest", "chats match on agent name")
    let newChats = CommandPalette.newChatItems(gateway: gateway)
    check(newChats.count == gateway.agents.count && newChats.contains { $0.action == .newChat(gatewayId: gateway.id, agentId: "research") },
          "a New Chat item per agent")
    check(CommandPalette.gatewayItems(gateways: [gateway], selectedGatewayId: gateway.id).isEmpty, "no gateway switching with one gateway")
    if let mainRow = gateway.sessions[key] {
        let models = CommandPalette.modelItems(gateway: gateway, row: mainRow)
        check(models.first?.action == .setModel(nil) && models.count == (gateway.modelCatalogs["main"]?.count ?? 0) + 1,
              "models page lists default plus the catalog")
        check(models.first { $0.action == .setModel("openai/gpt-5.6-sol") }?.subtitle?.hasSuffix("Current") == true,
              "models page marks the session's model")
    }
    await gateway.patch(coderKey, ["pinned": false])
    let unpinned = await waitFor("unpin") { gateway.pinnedChats.count == 3 }
    check(unpinned && Set(gateway.pinnedChats.map(\.key)) == seededPins, "unpinning restores the seeded pins")
    await checkDemoSentMessageSearch(gateway, chat)
    await runDemoExecPolicy(gateway, chat: chat)
    await runDemoAgents(gateway)
    await runDemoSubagents(gateway)
    await runDemoDevices(gateway)
    await runDemoSkills(gateway)
    await runMessageEditChecks(gateway, admin: true, "demo")
    await runDemoSessions(gateway)

    // Pairing Requests: the demo grants operator.pairing (settings stay read-only).
    let pairing = gateway.pairingInbox
    check(pairing.canManage && !gateway.settings.canEdit && pairing.supported, "demo can review pairing requests, settings read-only")
    await pairing.seed()
    check(pairing.hasLoaded && pairing.requests.count == 3 && pairing.pendingCount() == 3 && pairing.accounts.count == 2,
          "demo pairing list (\(pairing.requests.map(\.requestId)))")
    check(pairing.showsChannelFilter && pairing.commandOwnerConfigured && !pairing.canBootstrapCommandOwner,
          "demo spans Telegram and Discord; command owner configured")
    check(pairing.requests.map(\.title).contains("Maya Chen") && pairing.requests.contains { $0.title == $0.senderId && $0.channel == "discord" }
          && pairing.requests.contains { $0.title == "@night_owl" && ($0.expiresAt?.timeIntervalSinceNow ?? 0) < 180 },
          "demo titles and the request about to expire")
    if let maya = pairing.requests.first(where: { $0.title == "Maya Chen" }),
       let discord = pairing.requests.first(where: { $0.channel == "discord" })
    {
        check(maya.notifySupported && !discord.notifySupported && discord.accountLine == "Discord · Family server", "demo notify support per account")
        let approved = await pairing.approve(maya, notify: true)
        check(approved && pairing.notice == nil && !pairing.requests.contains { $0.id == maya.id }, "demo approve")
        let dismissed = await pairing.dismiss(discord)
        check(dismissed && pairing.requests.count == 1 && pairing.pendingCount() == 1, "demo dismiss")
        await pairing.approve(maya)
        check(pairing.notice?.text == PairingInboxModel.staleMessage && pairing.requests.count == 1, "demo stale request")
    }
    await checkDemoPairingShapes()
    // Health page and a simulated restart.
    let health = gateway.health
    check(health.health != nil && health.issues.contains { $0.id.hasPrefix("channel:telegram") } && health.indicator == nil,
          "demo sidebar quiet right after connecting, before any load (\(String(describing: health.indicator)))")
    await health.load()
    check(health.hasLoaded && health.level == .degraded && health.issues.contains { $0.id.hasPrefix("channel:telegram") },
          "demo health degraded by Telegram (\(health.issues.map(\.title)))")
    check(health.indicator == nil && !health.quietedIssueIds.isEmpty, "demo sidebar stays quiet about the Telegram issue at first")
    health.markIssuesViewed()
    check(health.level == .degraded && health.indicator == .degraded(issues: 1), "demo indicator returns once Health is viewed")
    check(health.presence.count == 3 && health.sortedPresence.first.map(health.isThisDevice) == true, "demo clients, this device first")
    check(health.heartbeat?.status == .okToken && (health.uptime() ?? 0) > 3 * 86_400, "demo heartbeat and uptime")
    check(health.canRestart, "demo can restart")
    // Dismissing the Telegram issue makes the Gateway Healthy until it changes; Restore brings it back.
    if let telegram = health.activeIssues.first(where: { $0.id.hasPrefix("channel:telegram") }) {
        let firstSync = await waitFor("demo health dismissals first sync") {
            UserDefaults.standard.bool(forKey: "pincer.healthDismissalsSynced.\(gateway.id.uuidString)")
        }
        check(firstSync, "demo health dismissals synced with users.prefs")
        health.dismiss(telegram)
        check(health.level == .healthy && health.indicator == nil && health.dismissedIssues.map(\.id) == [telegram.id]
              && gateway.healthDismissals[telegram.id] == "until:state=not-connected", "demo dismiss hides the Telegram issue")
        // The demo's users.prefs.set echoes users.prefs.changed and the store re-reads users.prefs.get,
        // replacing the local copy with the Gateway's.
        // Negative window: the echoed users.prefs must not replace the dismissal.
        try? await Task.sleep(for: .milliseconds(500))
        check(gateway.healthDismissals == [telegram.id: "until:state=not-connected"] && health.level == .healthy,
              "demo dismissal kept after re-reading users.prefs (\(gateway.healthDismissals))")
        health.restore(id: telegram.id)
        check(health.level == .degraded && health.dismissedIssues.isEmpty && gateway.healthDismissals.isEmpty, "demo restore")
        health.dismiss(telegram)
    } else {
        check(false, "demo Telegram issue to dismiss")
    }
    health.markRestartRequired("Saved. Restart the Gateway to finish applying it.")
    check(health.indicator == .restartNeeded, "restart needed indicator")
    await health.restart()
    check(health.restartState == .scheduled(coalesced: false), "demo restart scheduled (\(health.restartState))")
    let restarted = await waitFor("demo restart", timeout: 20) {
        if case .restarted = health.restartState { return gateway.state.isConnected }
        return false
    }
    check(restarted && (health.uptime() ?? .infinity) < 60 && health.restartRequiredReason == nil,
          "demo restarted with a fresh uptime (\(health.restartState))")
    check(gateway.sessions[key] != nil, "sessions survive the restart")
    let recovered = await waitFor("demo health reloaded") { health.level == .healthy }
    check(recovered && health.issues.isEmpty
          && health.health?.channels.first { $0.id == "telegram" }?.status == .connected, "Telegram recovers after the demo restart")
    check(gateway.healthDismissals.isEmpty, "the recovered Telegram issue's dismissal is pruned (\(gateway.healthDismissals))")
    // Negative window: the prune sync must leave the dismissals empty.
    try? await Task.sleep(for: .milliseconds(500))
    check(gateway.healthDismissals.isEmpty, "the prune synced to users.prefs (\(gateway.healthDismissals))")
    check(health.presence.first(where: health.isThisDevice)?.host?.hasPrefix("Pincer on ") == true, "this device named, not \"This device\"")

    // A streaming reply defers the restart; "Restart Now Anyway" goes ahead.
    health.dismissRestartStatus()
    let running = gateway.chat(for: key)
    await running.send("show me a tool and an image")
    let streaming = await waitFor("demo run started") { running.isRunning }
    await health.restart()
    if case let .waiting(message) = health.restartState {
        check(streaming && message.hasPrefix("Waiting for 1 active task") && health.canForceRestart,
              "demo restart waits for the running reply (\(message))")
    } else {
        check(false, "demo restart deferred (\(health.restartState))")
    }
    await health.restart(skipDeferral: true)
    let forced = await waitFor("forced demo restart", timeout: 20) {
        if case .restarted = health.restartState { return gateway.state.isConnected }
        return false
    }
    check(forced && !running.isRunning, "Restart Now Anyway restarts without waiting (\(health.restartState))")
    gateway.stop()
    for prefix in ["healthDismissals", "healthDismissalsSynced"] {
        UserDefaults.standard.removeObject(forKey: "pincer.\(prefix).\(gateway.id.uuidString)")
    }
}

/// The demo's `channels.pairing.*` replies use exactly the upstream keys (closed objects).
@MainActor
func checkDemoPairingShapes() async {
    let connection = GatewayConnection(profile: .demo())
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    guard await waitFor("demo raw connection", timeout: 10, { ready.value }) else {
        check(false, "demo raw connection")
        return
    }
    let accountKeys: Set<String> = ["channel", "channelLabel", "accountId", "accountLabel", "notifySupported"]
    let requestKeys: Set<String> = ["requestId", "channel", "channelLabel", "accountId", "accountLabel", "senderId", "senderLabel",
                                    "metadata", "createdAt", "lastSeenAt", "expiresAt", "notifySupported"]
    func keys(_ value: JSONValue?) -> Set<String> { Set(value?.object?.keys.map(\.self) ?? []) }
    do {
        let list = try await connection.request("channels.pairing.list", [:])
        check(keys(list) == ["accounts", "requests", "commandOwnerConfigured", "limits"] && keys(list["limits"]) == ["pendingPerAccount", "ttlMs"],
              "demo list result keys (\(keys(list).sorted()))")
        check((list["accounts"]?.array ?? []).allSatisfy { keys($0).isSubset(of: accountKeys) && keys($0).isSuperset(of: accountKeys.subtracting(["accountLabel"])) },
              "demo account keys")
        let requests = list["requests"]?.array ?? []
        check(requests.count == 3 && requests.allSatisfy {
            keys($0).isSubset(of: requestKeys) && keys($0).isSuperset(of: requestKeys.subtracting(["accountLabel", "metadata"]))
                && ($0["accountLabel"].map { $0.text != nil } ?? true)
                && ($0["metadata"]?.object?.values.allSatisfy { $0.text != nil } ?? true)
        }, "demo request keys")
        check(requests.contains { $0["metadata"] == nil && $0["channel"]?.text == "discord" }, "demo Discord request has senderId only")
        let maya = requests.first { $0["metadata"]?["name"]?.text == "Maya Chen" }
        let approve = try await connection.request("channels.pairing.approve",
                                                   ["channel": "telegram", "accountId": "home", "requestId": maya?["requestId"] ?? .null, "notify": true])
        check(keys(approve) == ["requestId", "senderId", "notification", "commandOwnerBootstrap"]
              && approve["notification"]?.text == "sent" && approve["commandOwnerBootstrap"]?.text == "not-requested", "demo approve result keys")
        let discord = requests.first { $0["channel"]?.text == "discord" }
        let dismiss = try await connection.request("channels.pairing.dismiss",
                                                   ["channel": "discord", "accountId": "family", "requestId": discord?["requestId"] ?? .null])
        check(keys(dismiss) == ["requestId", "senderId"] && dismiss["senderId"]?.text == "418820017734812160", "demo dismiss result keys")
        do {
            _ = try await connection.request("channels.pairing.dismiss", ["channel": "slack", "accountId": "work", "requestId": "x"])
            check(false, "demo not-pairing account refused")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "INVALID_REQUEST" && message == "channel account does not use DM pairing: slack:work", "demo not-pairing account refused")
        }
    } catch {
        check(false, "demo raw pairing calls (\(error))")
    }
    await connection.stop()
}
