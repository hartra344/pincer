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
func runMenuBarInboxChecks() async {
    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func row(_ key: String, _ fields: String = "", age: Double = 0) -> SessionRow {
            SessionRow(json(#"{"key":"\#(key)","updatedAt":\#(1_000_000_000 - age)\#(fields.isEmpty ? "" : "," + fields)}"#))!
        }
        func approval(_ id: String, session: String? = nil, expiresAtMs: Double? = nil) -> ExecApproval {
            var request: [String: JSONValue] = ["command": "rm -rf ./build"]
            if let session { request["sessionKey"] = .string(session) }
            var payload: [String: JSONValue] = ["id": .string(id), "request": .object(request)]
            if let expiresAtMs { payload["expiresAtMs"] = .number(expiresAtMs) }
            return ExecApproval(.object(payload))!
        }
        let question = QuestionPrompt(json(#"""
        {"id":"q1","sessionKey":"agent:main:asked","questions":[{"questionId":"q","header":"Cleanup","question":"What do you want removed?"}]}
        """#))!
        let agents = [AgentSummary(id: "main", name: "Claw", emoji: "🦞"), AgentSummary(id: "coder", name: "Forge")]
        let sessions = [
            row("agent:coder:main", #""label":"Main","unread":true"#, age: 50),
            row("agent:main:asked", #""label":"Asked","unread":true"#, age: 40),
            row("agent:main:busy", #""label":"Busy","unread":true,"hasActiveRun":true"#, age: 30),
            row("agent:main:discord:channel:1", #""label":"home-lab","unread":true"#, age: 10),
            row("agent:main:old", #""label":"Old","unread":true,"archived":true"#),
            row("agent:main:subagent:x", #""unread":true,"hasActiveRun":true"#),
        ]
        let home = MenuBarInbox.GatewayInput(name: "Home", state: .connected, sessions: sessions,
                                             approvals: [approval("a1", session: "agent:coder:main"), approval("a2", expiresAtMs: 1)],
                                             questions: [question], agents: agents)
        let inbox = MenuBarInbox.build([home], now: now)
        check(inbox.needsYou.map(\.title) == ["Approve: rm -rf ./build — Main · Forge", "Question: What do you want removed? — 🦞 Asked · Claw"],
              "needs you: approvals, then questions, expired left out (\(inbox.needsYou.map(\.title)))")
        check(inbox.running.map(\.title) == ["🦞 Busy · Claw"] && inbox.unread.map(\.title) == ["🦞 home-lab · Claw"],
              "running and unread deduped, subagent and archived rows left out")
        check(inbox.needsYou.map { $0.displayTitle(showingPet: true) } == ["Approve: rm -rf ./build — Main · Forge", "Question: What do you want removed? — Asked · Claw"],
              "pet rows retain approval and question text without duplicating agent emoji")
        check(inbox.running.first?.displayTitle(showingPet: true) == "Busy · Claw"
              && inbox.unread.first?.displayTitle(showingPet: true) == "home-lab · Claw"
              && inbox.unread.first?.displayTitle(showingPet: false) == "🦞 home-lab · Claw",
              "pet rows keep human names; text-only rows keep their original emoji")
        check(inbox.unreadCount == 4 && inbox.needsYouCount == 2 && inbox.badgeText == "6"
              && inbox.accessibilityLabel == "Pincer, 4 unread, 2 need you", "menu bar counts include deduped chats")
        check(inbox.needsYou.first?.target == Notifier.Target(gatewayId: home.id, sessionKey: "agent:coder:main")
              && inbox.unread.first?.target == Notifier.Target(gatewayId: home.id, sessionKey: "agent:main:discord:channel:1"),
              "rows open their chat")
        let many = MenuBarInbox.GatewayInput(name: "Home", state: .connected,
                                             sessions: (1...10).map { row("agent:main:u\($0)", #""unread":true"#, age: Double($0)) },
                                             approvals: (1...7).map { approval("a\($0)") })
        let offline = MenuBarInbox.GatewayInput(name: "Work", state: .failed("unauthorized"), sessions: sessions, approvals: [approval("x")])
        let capped = MenuBarInbox.build([many, offline], now: now)
        check(capped.needsYou.count == 5 && capped.needsYouOverflow == 2 && capped.unread.count == 8 && capped.unreadOverflow == 2
              && capped.unread.first?.title == "u1 · Main — Home", "caps of 5 and 8 with overflow; gateway named with several")
        check(capped.gateways.map(\.title) == ["Home — Connected", "Work — Can't connect"] && capped.unreadCount == 10,
              "a gateway that isn't connected only shows its status")
        check(MenuBarInbox.build([offline], now: now).isEmpty && !MenuBarInbox.build([offline], now: now).isCaughtUp
              && MenuBarInbox.build([MenuBarInbox.GatewayInput(name: "Quiet", state: .connected)], now: now).isCaughtUp,
              "caught up only with a connected gateway")
        check(MenuBarInbox.statusText(state: .reconnecting(attempt: 1, delaySeconds: 1, reason: "x"), healthLevel: .down).text == "Reconnecting…"
              && MenuBarInbox.statusText(state: .connected, healthLevel: .restarting).text == "Restarting…"
              && MenuBarInbox.statusText(state: .awaitingPairing(requestId: nil, deviceId: "d"), healthLevel: .down).symbol == "hourglass",
              "gateway status wording")
        let (defaults, suite) = scratchDefaults()
        let settings = MenuBarSettings(defaults: defaults)
        check(!settings.isEnabled, "the menu bar item starts off")
        settings.isEnabled = true
        check(MenuBarSettings(defaults: defaults).isEnabled, "turning it on is saved")
        var badge = MenuBarInbox()
        badge.unreadCount = 100
        check(badge.badgeText == "99+" && MenuBarInbox.truncated(String(repeating: "x", count: 41)) == String(repeating: "x", count: 39) + "…"
              && MenuBarSettings.enabledKey == "pincer.menuBar.enabled", "badge caps at 99+, text cut at 40")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// The menu bar inbox over the demo: the seeded approval, unread chats, opening rows, and live updates.
@MainActor
func runMenuBarDemo() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo connection") { gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.approvals.isEmpty }
    check(ready, "menu bar demo connected")
    guard ready else { return }
    let coderKey = "agent:coder:main"
    let homeLab = "agent:main:discord:channel:123"
    let papers = "agent:research:dashboard:papers"

    var inbox = MenuBarInbox(app: app)
    let seeded = inbox.needsYou.first { $0.kind == .approval }
    check(inbox.needsYou.count == 1 && seeded?.target == Notifier.Target(gatewayId: gateway.id, sessionKey: coderKey)
          && seeded?.title == "Approve: git push origin fix/login-timeout — 🛠️ Main · Forge",
          "the seeded approval needs you, in Forge's Main chat (\(inbox.needsYou.map(\.title)))")
    check(seeded?.displayTitle(showingPet: true) == "Approve: git push origin fix/login-timeout — Main · Forge"
          && inbox.unread.map { $0.displayTitle(showingPet: true) } == ["home-lab · Claw", "Paper digest · Scout"],
          "demo menu pet titles keep approval details and human agent names without duplicate emoji")
    check(inbox.unread.map { $0.displayTitle(showingPet: false) } == inbox.unread.map(\.title),
          "demo menu text-only titles retain the original emoji")
    // Forge's Main is unread too, but it's listed once, under Needs You; the count still includes it.
    check(Set(inbox.unread.map(\.target.sessionKey)) == [homeLab, papers] && inbox.unreadCount == 3
          && inbox.unread.map(\.title) == ["🦞 home-lab · Claw", "🔭 Paper digest · Scout"],
          "unread lists home-lab and Paper digest (\(inbox.unread.map(\.title)), \(inbox.unreadCount) unread)")
    // Forge's "Fix retry backoff" opens mid-run, and so does the Sessions page's seeded run (#38); running chats don't add to the badge.
    let seededRun = "agent:coder:dashboard:refactor"
    check(Set(inbox.running.map(\.target.sessionKey)) == ["agent:coder:dashboard:retry-fix", seededRun] && !inbox.isCaughtUp && inbox.badgeText == "4",
          "only the seeded runs are running; the icon shows 4 (\(inbox.running.map(\.title)), \(inbox.badgeText ?? "none"))")
    check(seeded?.agentId == "coder" && seeded?.pose == .awaitingApproval
          && inbox.running.allSatisfy { $0.pose == .thinking },
          "menu bar pets: actual approval and running rows provide their still poses")
    check(Set(inbox.unread.compactMap(\.agentId)) == ["main", "research"]
          && inbox.unread.allSatisfy { $0.pose == .idle },
          "menu bar pets: actual unread rows retain their agent identities and idle poses")
    // #9: the menu takes `now` from a tick, not body. Past its 30 minutes the seeded approval drops out.
    let expired = MenuBarInbox(app: app, now: Date().addingTimeInterval(31 * 60))
    check(expired.needsYou.isEmpty && expired.needsYouCount == 0 && expired.badgeText == "3" && !expired.accessibilityLabel.contains("need"),
          "31 minutes on, the expired seeded approval leaves Needs You and the badge (\(expired.badgeText ?? "none"))")
    check(MenuBarInbox(app: app).needsYouCount == 1, "…and is still listed now")
    // The demo's Telegram account is unhealthy until a restart, so its health reads degraded once loaded.
    let degraded = await waitFor("demo health", timeout: 5) { MenuBarInbox(app: app).gateways.first?.text == "Degraded" }
    inbox = MenuBarInbox(app: app)
    check(degraded && inbox.gateways.map(\.name) == ["Demo"] && inbox.gateways.first?.symbol == "exclamationmark.triangle"
          && MenuBarInbox.statusText(state: gateway.state, healthLevel: .healthy).text == "Connected",
          "the demo's status follows its health (\(inbox.gateways.map(\.title)))")
    await checkMenuBarDemoDismissals(app, gateway, defaults: defaults)

    if let seeded {
        app.open(seeded.target)
        check(app.selectedGatewayId == gateway.id && gateway.selectedKey == coderKey, "an approval row opens its chat")
    }
    if let status = inbox.gateways.first {
        let opens = app.openRequests
        app.open(Notifier.Target(gatewayId: status.id, sessionKey: ""))
        check(app.selectedGatewayId == gateway.id && gateway.selectedKey == coderKey && app.openRequests == opens + 1,
              "a gateway row selects the gateway and keeps its chat")
    }

    await gateway.markRead(papers)
    // Opening Forge's Main above marks it read asynchronously too, so wait for both to land.
    let markedRead = await waitFor("mark read") {
        let now = MenuBarInbox(app: app)
        return now.unreadCount == 1 && now.unread.map(\.target.sessionKey) == [homeLab]
    }
    inbox = MenuBarInbox(app: app)
    check(markedRead && inbox.unreadCount == 1 && inbox.unread.map(\.target.sessionKey) == [homeLab], "a chat marked read leaves Unread (\(inbox.unreadCount) unread)")

    let tripKey = "agent:main:dashboard:trip"
    let trip = gateway.chat(for: tripKey)
    await trip.send("please approve this")
    let raised = await waitFor("second approval") { MenuBarInbox(app: app).needsYou.count == 2 }
    inbox = MenuBarInbox(app: app)
    check(raised && inbox.needsYou.last?.target.sessionKey == tripKey && inbox.needsYou.last?.title.hasPrefix("Approve: rm -rf ./build") == true
          && !inbox.running.contains { $0.target.sessionKey == tripKey }, "a new approval adds a Needs You row, not a Running one")
    if let approval = gateway.approvals.first(where: { $0.sessionKey == tripKey }) {
        await gateway.resolveApproval(approval, decision: "deny")
        check(MenuBarInbox(app: app).needsYou.map(\.target.sessionKey) == [coderKey], "resolving it removes the row")
    } else {
        check(false, "the demo raised an approval in the trip chat")
    }
    _ = await waitFor("approval reply", timeout: 20) { !trip.isRunning && gateway.sessions[tripKey]?.hasActiveRun != true }

    await trip.send("hello")
    let streaming = await waitFor("demo run in the menu", every: 10) {
        MenuBarInbox(app: app).running.contains { $0.target.sessionKey == tripKey }
    }
    check(streaming, "a streaming reply shows under Running")
    let finished = await waitFor("demo run finished", timeout: 20) {
        !trip.isRunning && !MenuBarInbox(app: app).running.contains { $0.target.sessionKey == tripKey }
    }
    check(finished, "the chat leaves Running once the reply finishes")
    check(MenuBarInbox(app: app).needsYou.map(\.target.sessionKey) == [coderKey], "the seeded approval is still pending")

    // The seeded approval matches §8 and resolves like any demo approval, landing in Approval History.
    if let pending = gateway.approvals.first(where: { $0.sessionKey == coderKey }) {
        let expiresIn = pending.expiresAt.map { $0.timeIntervalSinceNow } ?? 0
        check(pending.id == "approval_demo_push" && pending.command == "git push origin fix/login-timeout"
              && pending.cwd == "/home/claw/projects/pincer" && pending.agentId == "coder"
              && pending.allowedDecisions == ["allow-once", "allow-always", "deny"]
              && expiresIn > 25 * 60 && expiresIn <= 30 * 60 && !pending.isExpired(at: Date())
              && pending.isExpired(at: Date().addingTimeInterval(31 * 60)),
              "the seeded approval has its command details and expires 30 minutes after it was raised (\(Int(expiresIn))s left)")
        let history = gateway.approvalHistory
        await history.refresh()
        await gateway.resolveApproval(pending, decision: "deny")
        inbox = MenuBarInbox(app: app)
        check(inbox.needsYou.isEmpty && inbox.needsYouCount == 0 && !inbox.accessibilityLabel.contains("need"),
              "resolving the seeded approval empties Needs You (\(inbox.accessibilityLabel))")
        let recorded = await waitFor("seeded approval in history", timeout: 5) { history.items.first?.id == pending.id }
        check(recorded && history.items.first?.sessionKey == coderKey, "the resolved seeded approval shows in Approval History")
        for row in gateway.sessions.values where row.isUnread { await gateway.markRead(row.key) }
        await gateway.chat(for: "agent:coder:dashboard:retry-fix").abort()
        await gateway.chat(for: seededRun).abort()
        let caughtUp = await waitFor("caught up") { MenuBarInbox(app: app).isCaughtUp }
        check(caughtUp && MenuBarInbox(app: app).badgeText == nil, "with nothing left the menu is all caught up")
    } else {
        check(false, "the seeded approval is still there to resolve")
    }
}

/// Set by `withObservationTracking`'s `onChange`.
final class ObservationTripwire: @unchecked Sendable {
    var fired = false

    /// Tracks what `read` reads; `fired` turns true once any of it changes.
    @MainActor
    static func track(_ read: () -> Void) -> ObservationTripwire {
        let tripwire = ObservationTripwire()
        withObservationTracking(read) { tripwire.fired = true }
        return tripwire
    }
}

/// #119: with a health dismissal stored, building the menu (as the menu bar label's body does on
/// every update) changes nothing it reads, and dismissing the same issue again is a no-op.
@MainActor
func checkMenuBarDemoDismissals(_ app: AppModel, _ gateway: GatewayStore, defaults: UserDefaults) async {
    let health = gateway.health
    guard let telegram = health.activeIssues.first(where: { $0.id.hasPrefix("channel:telegram") }) else {
        check(false, "menu bar demo: a Telegram issue to dismiss (\(health.activeIssues.map(\.id)))")
        return
    }
    let synced = await waitFor("menu bar demo dismissals first sync") {
        defaults.bool(forKey: "pincer.healthDismissalsSynced.\(gateway.id.uuidString)")
    }
    check(synced, "menu bar demo: health dismissals synced with users.prefs")
    let ingress = health.activeIssues.filter { $0.id.hasPrefix("queue:ingress-") }
    check(ingress.count == 2 && ingress.allSatisfy { $0.kind == .delivery && !$0.canAlwaysIgnore },
          "menu bar demo: both ingress issues are visible and account-scoped")
    health.dismiss(telegram)
    check(MenuBarInbox(app: app).gateways.first?.text == "Degraded" && health.activeIssues.count == 2,
          "dismissing only Telegram leaves both ingress issues visible in the menu")
    for issue in ingress { health.dismiss(issue) }
    let expectedDismissals = Dictionary(uniqueKeysWithValues: (ingress + [telegram]).map { ($0.id, "until:" + $0.fingerprint) })
    // The users.prefs.set round trip: the demo echoes users.prefs.changed and the store re-reads it.
    // Negative window: the echo must leave the stored dismissals unchanged.
    try? await Task.sleep(for: .milliseconds(500))
    let dismissed = gateway.healthDismissals
    check(dismissed == expectedDismissals && health.dismissals == dismissed,
          "menu bar demo: the Telegram dismissal is stored (\(dismissed))")
    let stored = defaults.dictionary(forKey: "pincer.healthDismissals.\(gateway.id.uuidString)") as? [String: String]

    var built = MenuBarInbox()
    let tripwire = ObservationTripwire.track { built = MenuBarInbox(app: app) }
    for _ in 0..<20 { _ = MenuBarInbox(app: app) }
    check(!tripwire.fired, "building the menu with a dismissal stored changes nothing the menu reads")
    check(built.gateways.first?.text == "Connected" && built.badgeText == "4",
          "a dismissed issue leaves the demo Connected in the menu (\(built.gateways.map(\.title)), \(built.badgeText ?? "none"))")
    check(gateway.healthDismissals == dismissed && health.dismissals == dismissed
          && defaults.dictionary(forKey: "pincer.healthDismissals.\(gateway.id.uuidString)") as? [String: String] == stored,
          "building the menu leaves the dismissals alone (\(gateway.healthDismissals))")

    let again = ObservationTripwire.track { _ = gateway.healthDismissals; _ = health.dismissals }
    health.dismiss(telegram)
    check(!again.fired, "dismissing the Telegram issue again writes nothing")
    // Negative window: a repeated dismissal must not write users.prefs.
    try? await Task.sleep(for: .milliseconds(300))
    check(gateway.healthDismissals == dismissed, "the repeated dismissal leaves users.prefs as it was (\(gateway.healthDismissals))")

    for issue in ingress { health.restore(id: issue.id) }
    health.restore(id: telegram.id)
    // Round trip through users.prefs: restore echoes users.prefs.changed; the state below is read after it.
    try? await Task.sleep(for: .milliseconds(300))
    let inbox = MenuBarInbox(app: app)
    check(gateway.healthDismissals.isEmpty && inbox.gateways.first?.text == "Degraded"
          && Set(health.activeIssues.map(\.id)) == Set(expectedDismissals.keys),
          "restoring it brings Degraded back to the menu (\(inbox.gateways.map(\.title)))")
}
