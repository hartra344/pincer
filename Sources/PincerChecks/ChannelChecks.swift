import Foundation
import PincerKit

// Channel status and lifecycle (#31): the rules and model against a scripted Gateway, then the
// demo and a (mock) Gateway end to end, including Reconnect Account from Gateway Health.

private let telegramKey = ChannelAccountKey(channel: "telegram", accountId: "default")
private let discordKey = ChannelAccountKey(channel: "discord", accountId: "default")
private let whatsappKey = ChannelAccountKey(channel: "whatsapp", accountId: "default")

@MainActor
func checkChannelStatus() async {
    print("Channel status")
    let status = json(#"""
    {"ts":1700000000000,"channelOrder":["discord","telegram","whatsapp"],
     "channelLabels":{"discord":"Discord","telegram":"Telegram","whatsapp":"WhatsApp"},
     "channels":{},"channelDefaultAccountId":{"discord":"default","telegram":"default","whatsapp":"default"},
     "channelAccounts":{
       "discord":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true,
                   "lastInboundAt":1699999000000,"lastOutboundAt":1699999500000}],
       "telegram":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":false,
                    "healthState":"disconnected","lastError":"getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"},
                   {"accountId":"work","name":"Work bot","enabled":true,"configured":true,"running":false}],
       "whatsapp":[{"accountId":"default","enabled":true,"configured":false,"linked":false,"running":false}]},
     "statusIssues":[{"channel":"whatsapp","accountId":"default","kind":"auth","message":"Not linked"}]}
    """#)
    guard let snapshot = ChannelsStatusSnapshot(status) else {
        check(false, "channels.status parses")
        return
    }
    let work = ChannelAccountKey(channel: "telegram", accountId: "work")
    check(snapshot.channels.map(\.id) == ["discord", "telegram", "whatsapp"] && snapshot.channel("telegram")?.accounts.count == 2,
          "channels in order, Telegram with two accounts")
    check(snapshot.state(of: discordKey) == .connected && snapshot.state(of: work) == .stopped
          && snapshot.state(of: whatsappKey) == .loggedOut && snapshot.state(of: telegramKey) == .degraded,
          "badges: connected, stopped, logged out, Telegram needs attention (\(String(describing: snapshot.state(of: telegramKey))))")
    check(snapshot.account(discordKey)?.lastActivityAt == Date(timeIntervalSince1970: 1_699_999_500), "last activity is the latest message")
    check(snapshot.account(telegramKey)?.lastError == "getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running",
          "full channel error text is preserved for disclosure")
    check(snapshot.issues(for: whatsappKey).map(\.kind) == ["auth"], "status issues keyed by account")
    check(ChannelAccountKey(healthIssueId: "channel:telegram:work") == work && ChannelAccountKey(healthIssueId: "plugin:telegram") == nil,
          "Health issue ids map to accounts")
    check(ChannelAccountState.allCases.allSatisfy { !$0.label.isEmpty } && ChannelAccountState.loggedOut.label == "Logged Out",
          "every badge has a text label")
    check(ChannelAccountState.loggedOut.symbol == "person.crop.circle.badge.xmark"
          && ChannelAccountState.loggedOut.needsAttention && !ChannelAccountState.loggedOut.isHealthy,
          "logged-out badge keeps its account icon and attention state")

    // The model against a scripted Gateway: reconnect is stop then start, with exactly {channel, accountId}.
    var calls: [(String, JSONValue)] = []
    var telegramFixed = false
    let fixedStatus = json(#"""
    {"channelOrder":["telegram"],"channelLabels":{"telegram":"Telegram"},"channels":{},
     "channelAccounts":{"telegram":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true}]}}
    """#)
    let request: ChannelsModel.Request = { method, params in
        calls.append((method, params))
        switch method {
        case "channels.status": return telegramFixed ? fixedStatus : status
        case "channels.stop": return ["channel": "telegram", "accountId": "default", "stopped": true]
        case "channels.start":
            telegramFixed = true
            return ["channel": "telegram", "accountId": "default", "started": true, "outcome": ["status": "handed-off"]]
        default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
        }
    }
    let admin = ChannelsModel(methods: { ["channels.status", "channels.start", "channels.stop", "channels.logout"] },
                              scopes: { [GatewayConnection.adminScope] }, request: request)
    var changed = false
    admin.onChanged = { changed = true }
    await admin.load()
    check(admin.hasLoaded && admin.attentionCount == 3, "attention count: Telegram twice and WhatsApp (\(admin.attentionCount))")
    calls = []
    let reconnected = await admin.reconnect(telegramKey)
    let expected: JSONValue = ["channel": "telegram", "accountId": "default"]
    check(reconnected && calls.map(\.0) == ["channels.stop", "channels.start", "channels.status"]
          && calls.prefix(2).allSatisfy { $0.1 == expected }, "reconnect: stop, start, reload (\(calls.map(\.0)))")
    check(changed && admin.state(of: telegramKey) == .connected, "reconnect tells the store and the account is connected")

    let reader = ChannelsModel(methods: { ["channels.status", "channels.start", "channels.stop"] },
                               scopes: { ["operator.read"] }, request: request)
    await reader.load()
    calls = []
    let denied = await reader.stop(telegramKey)
    check(!reader.canManage && !denied && calls.isEmpty && reader.operation(for: telegramKey)?.state.error == SetupWizardModel.fullManagementMessage,
          "without Full Management nothing is sent")
    check(!reader.supports(.logout) && reader.supports(.reconnect), "actions follow the advertised methods")
    check(SetupWizardModel.fullManagementTitle == "Needs Full Management"
          && SetupWizardModel.fullManagementMessage == "This device can view but not change this. Open Connection to request Full Management.",
          "scope lock uses the shared Full Management copy")
}

/// A fresh demo Gateway (the main demo run keeps Telegram degraded for its Health checks).
@MainActor
func runDemoChannels() async {
    let profile = GatewayProfile.demo()
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let up = await waitFor("demo for channels") { gateway.state.isConnected && gateway.hello != nil }
    check(up, "demo for channels connected")
    guard up else { return }
    defer { gateway.stop() }
    let channels = gateway.channels
    let health = gateway.health
    check(gateway.hello?.methods.contains("channels.stop") == true && channels.supported, "demo advertises channel lifecycle")
    await channels.load()
    await health.load()
    check(channels.hasLoaded && channels.canManage, "demo loads channels and manages them without admin")
    check(channels.state(of: discordKey) == .connected && channels.account(discordKey)?.lastActivityAt != nil,
          "demo Discord connected with recent activity (\(channels.state(of: discordKey)))")
    let telegramError = channels.account(telegramKey)?.lastError
    check(channels.state(of: telegramKey) == .degraded
          && telegramError?.contains("409 Conflict") == true
          && telegramError?.contains("make sure that only one bot instance is running") == true,
          "demo Telegram keeps the complete 409 error available for disclosure (\(channels.state(of: telegramKey)))")
    let loggedOutWhatsApp = channels.state(of: whatsappKey)
    check(loggedOutWhatsApp == .loggedOut && channels.canLogIn(whatsappKey), "demo WhatsApp logged out, QR login offered")
    check(loggedOutWhatsApp.label == "Logged Out" && loggedOutWhatsApp.symbol == "person.crop.circle.badge.xmark"
          && loggedOutWhatsApp.needsAttention && !loggedOutWhatsApp.isHealthy,
          "demo logged-out badge keeps its accessible identity and attention state")
    check(channels.attentionCount == 2, "demo attention: Telegram and WhatsApp (\(channels.attentionCount))")
    let telegramIssue = health.activeIssues.first { $0.channelAccount == telegramKey }
    check(telegramIssue?.offersReconnect == true && !health.activeIssues.contains { $0.channelAccount == whatsappKey },
          "demo Health raises Telegram (not the unconfigured WhatsApp) with Reconnect Account (\(health.activeIssues.map(\.id)))")

    let skippedStart = await channels.start(whatsappKey)
    check(!skippedStart && channels.notice?.severity == .error && !SettingsNoticePolicy.shouldAutoDismiss(.error),
          "settings notices demo: logged-out channel errors wait for explicit dismissal")
    channels.clearNotice()

    await channels.probe()
    check(!channels.isProbing && channels.account(discordKey)?.lastProbeAt != nil, "demo probe stamps lastProbeAt")

    // Reconnect Account from Health clears the issue.
    if let key = telegramIssue?.channelAccount {
        let ok = await channels.reconnect(key)
        check(ok && channels.state(of: key) == .connected && channels.account(key)?.lastError == nil, "demo reconnect fixes Telegram")
        check(channels.notice?.severity == .success && SettingsNoticePolicy.shouldAutoDismiss(.success),
              "settings notices demo: successful reconnect remains eligible for timeout")
        let cleared = await waitFor("demo Telegram issue cleared") { !health.issues.contains { $0.channelAccount == key } }
        check(cleared, "demo Health issue gone after reconnect (\(health.issues.map(\.id)))")
    }

    // Stop raises a Health issue; Start clears it.
    let stopped = await channels.stop(discordKey)
    check(stopped && channels.state(of: discordKey) == .stopped && channels.offers(.start, on: discordKey), "demo stop Discord")
    let discordIssue = await waitFor("demo Discord issue") { health.issues.contains { $0.channelAccount == discordKey } }
    check(discordIssue, "a stopped account is a Health issue")
    let started = await channels.start(discordKey)
    check(started && channels.state(of: discordKey) == .connected, "demo start Discord")
    let discordClear = await waitFor("demo Discord issue cleared") { !health.issues.contains { $0.channelAccount == discordKey } }
    check(discordClear, "starting clears it")
    let logoutDiscord = await channels.logout(discordKey)
    check(!logoutDiscord && channels.operation(for: discordKey)?.state.error == "Discord doesn't support logging out."
          && channels.state(of: discordKey) == .connected && !channels.offers(.logout, on: discordKey),
          "demo Discord logout unsupported, then hidden")

    // QR login links WhatsApp; logging out unlinks it again.
    channels.startQRLogin(whatsappKey)
    let linked = await waitFor("demo WhatsApp linked", timeout: 20) { channels.state(of: whatsappKey) == .connected }
    check(linked, "demo QR login links WhatsApp (\(channels.qr.state(channel: "whatsapp", accountId: "default")))")
    let loggedOut = await channels.logout(whatsappKey)
    check(loggedOut && channels.state(of: whatsappKey) == .loggedOut, "demo WhatsApp log out (\(channels.state(of: whatsappKey)))")
    check(channels.attentionCount == 1, "only WhatsApp needs attention now (\(channels.attentionCount))")
}

/// Against the mock, before its Health checks: a fresh standard-access store reads, `admin` has Full
/// Management. Ends with the seeded Telegram issue fixed through Reconnect Account and WhatsApp logged out again.
@MainActor
func runLiveChannels(profile: GatewayProfile, admin: GatewayStore) async {
    print("Channel status (live)")
    let readerProfile = GatewayProfile(name: "Channels reader", url: profile.url, authMode: .token)
    readerProfile.secret = profile.secret
    let readerStore = GatewayStore(profile: readerProfile)
    readerStore.start()
    defer { readerStore.stop() }
    let readerUp = await agentsReady(readerStore, "channels reader")
    let adminUp = await agentsReady(admin, "channels admin")
    check(readerUp && adminUp, "both stores connected for channel checks")
    check(readerStore.hello?.scopes.contains(GatewayConnection.adminScope) == false, "channels reader has no operator.admin")
    let methods = admin.hello?.methods ?? []
    check(["channels.status", "channels.start", "channels.stop", "channels.logout"].allSatisfy(methods.contains)
          && !methods.contains("web.login.start"), "mock advertises channel lifecycle, not web.login.*")

    // Standard access reads, but every action is locked and nothing is sent.
    let reader = readerStore.channels
    await reader.load()
    if reader.loadState.error != nil {
        await agentsReady(readerStore, "channels reader")
        await reader.load()
    }
    check(reader.hasLoaded && reader.snapshot?.channels.map(\.id) == ["discord", "telegram", "whatsapp", "slack"],
          "reader loads channels.status (\(reader.snapshot?.channels.map(\.id) ?? []), \(reader.loadState))")
    check(!reader.canManage && ChannelsModel.Action.allCases.allSatisfy { !reader.canPerform($0, on: telegramKey) }
          && !reader.canLogIn(whatsappKey), "reader can't run lifecycle actions")
    let readerStop = await reader.stop(telegramKey)
    check(!readerStop && reader.operation(for: telegramKey)?.state.error == SetupWizardModel.fullManagementMessage,
          "reader stop is refused locally")

    let channels = admin.channels
    await channels.load()
    check(channels.canManage, "admin manages channels")
    check(channels.state(of: discordKey) == .connected, "mock Discord connected")
    check(channels.state(of: telegramKey) == .degraded
          && channels.account(telegramKey)?.lastError?.contains("409 Conflict") == true, "mock Telegram degraded (409 Conflict)")
    check(channels.state(of: whatsappKey) == .loggedOut && channels.snapshot?.issues(for: whatsappKey).first?.kind == "auth",
          "mock WhatsApp logged out with an auth issue")
    check(channels.state(of: ChannelAccountKey(channel: "slack", accountId: nil)) == .disabled, "mock Slack disabled")
    await channels.probe()
    check(channels.account(telegramKey)?.probeOk == false && channels.account(discordKey)?.probeOk == true,
          "probe fails for Telegram, passes for Discord")

    // Stop / start Discord, and its unsupported logout.
    let stopped = await channels.stop(discordKey)
    check(stopped && channels.state(of: discordKey) == .stopped, "mock stop Discord (\(channels.state(of: discordKey)))")
    let started = await channels.start(discordKey)
    check(started && channels.state(of: discordKey) == .connected, "mock start Discord")
    let logoutDiscord = await channels.logout(discordKey)
    check(!logoutDiscord && channels.operation(for: discordKey)?.state.error == "Discord doesn't support logging out."
          && !channels.offers(.logout, on: discordKey),
          "Discord logout unsupported (\(String(describing: channels.operation(for: discordKey))))")

    // WhatsApp: start is skipped until linked; QR login links it; log out unlinks it again.
    let skipped = await channels.start(whatsappKey)
    check(!skipped && channels.notice?.isError == true, "start on logged-out WhatsApp is skipped (\(channels.notice?.text ?? "-"))")
    check(channels.notice?.severity == .error && !SettingsNoticePolicy.shouldAutoDismiss(.error),
          "settings notices live: the logged-out channel error persists until dismissed")
    channels.startQRLogin(whatsappKey)
    let linked = await waitFor("mock WhatsApp linked", timeout: 30) { channels.state(of: whatsappKey) == .connected }
    check(linked, "mock QR login links WhatsApp (\(channels.qr.state(channel: "whatsapp", accountId: "default")))")
    let loggedOut = await channels.logout(whatsappKey)
    check(loggedOut && channels.state(of: whatsappKey) == .loggedOut, "mock WhatsApp log out")

    // Reconnect Account from Gateway Health.
    let health = admin.health
    await health.load()
    guard let issue = health.activeIssues.first(where: { $0.channelAccount == telegramKey }) else {
        check(false, "mock Health raises the Telegram issue (\(health.activeIssues.map(\.id)))")
        return
    }
    check(issue.offersReconnect, "Telegram Health issue offers Reconnect Account")
    let reconnected = await channels.reconnect(telegramKey)
    check(reconnected && channels.state(of: telegramKey) == .connected && channels.account(telegramKey)?.lastError == nil,
          "mock reconnect fixes Telegram (\(channels.state(of: telegramKey)))")
    let cleared = await waitFor("mock Telegram issue cleared") { !health.issues.contains { $0.channelAccount == telegramKey } }
    check(cleared, "Telegram Health issue gone after Reconnect Account (\(health.issues.map(\.id)))")
    await reader.refresh()
    check(reader.state(of: telegramKey) == .connected, "other clients see Telegram connected (\(reader.state(of: telegramKey)))")
}
