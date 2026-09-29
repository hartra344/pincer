import Foundation
import PincerKit
import UserNotifications

// #260: the background-refresh engine against a (mock) Gateway, as a one-shot connection.

@MainActor
func runBackgroundRefreshLive(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    ClosedAppDelivery.set(.backgroundRefresh, defaults)
    defaults.set(true, forKey: "pincer.notifications")

    let profile = GatewayProfile(name: "Mock refresh", url: url, authMode: .token)
    profile.secret = token
    // The running app's own connection: it pairs the device and makes the new activity.
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    defer { gateway.stop() }
    let connected = await waitFor("refresh gateway", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "connected for background refresh")
    guard connected else { return }

    var posted: [UNNotificationRequest] = []
    let refresh = BackgroundRefresh(profiles: { [profile] }, connector: GatewayIntentConnector(),
                                    cursors: BackgroundRefreshCursorStore(defaults: defaults), defaults: defaults,
                                    post: { posted += $0 })

    // Seeding never moves a cursor backwards, and creates one at the live state.
    let store = BackgroundRefreshCursorStore(defaults: defaults)
    refresh.seed(from: [gateway])
    let live = gateway.sessions.values.map(\.activityMs).max() ?? 0
    check(store.cursor(for: profile.id)?.activityMs == live, "seed baselines at the live state")
    store.save(BackgroundRefreshCursor(activityMs: live + 1_000_000, approvalIds: [], questionIds: []), for: profile.id)
    refresh.seed(from: [gateway])
    check(store.cursor(for: profile.id)?.activityMs == live + 1_000_000, "seed never moves the cursor backwards")
    store.remove(for: profile.id)

    let baseline = await refresh.run()
    check(!baseline.skipped && baseline.posted == 0 && posted.isEmpty && baseline.failed.isEmpty && baseline.aborted.isEmpty,
          "baseline run posts nothing (\(baseline))")
    check(BackgroundRefreshCursorStore(defaults: defaults).cursor(for: profile.id) != nil, "baseline saves a cursor")

    let key = "agent:main:main"
    let chat = gateway.chat(for: key)
    await chat.send("hello from background refresh")
    _ = await waitFor("reply run", timeout: 20) { !chat.isRunning }
    _ = await waitFor("reply row unread", timeout: 10) { gateway.sessions[key]?.isUnread == true && gateway.sessions[key]?.hasActiveRun != true }

    let replies = await refresh.run()
    let reply = posted.first { $0.content.categoryIdentifier == "reply" }
    check(replies.posted >= 1 && reply != nil, "finished reply notifies (\(posted.map(\.identifier)))")
    check(reply?.content.threadIdentifier == "\(gateway.id.uuidString)|\(key)", "reply threads with its chat")
    check(reply?.identifier.hasPrefix("reply:\(key):") == true, "reply identifier matches the live path")
    check(reply?.content.userInfo["session"] as? String == key && reply?.content.userInfo["gateway"] as? String == gateway.id.uuidString,
          "reply opens its chat")

    let afterReply = posted.count
    let again = await refresh.run()
    check(again.posted == 0 && posted.count == afterReply, "second run dedupes")

    await chat.send("please approve this")
    let pending = await waitFor("pending approval", timeout: 20) { !gateway.approvals.isEmpty }
    check(pending, "mock raised an approval")
    if let approval = gateway.approvals.first {
        let approvals = await refresh.run()
        let request = posted.dropFirst(afterReply).first { $0.identifier == "approval:\(approval.id)" }
        check(approvals.posted >= 1 && request != nil, "pending approval notifies")
        check(request?.content.categoryIdentifier == Notifier.category(for: approval)
              && request?.content.userInfo["approval"] as? String == approval.id, "approval carries its actions")
        let afterApproval = posted.count
        let deduped = await refresh.run()
        check(deduped.posted == 0 && posted.count == afterApproval, "approval isn't repeated")
        _ = await gateway.resolveApproval(id: approval.id, decision: "deny")
    }
    _ = await waitFor("approval run to finish", timeout: 20) { !chat.isRunning }
}
