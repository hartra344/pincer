import Foundation
import Testing
@testable import PincerKit

/// `channels.status` fixtures in the Gateway's shapes (as `mock-gateway/channels.mjs` seeds them).
enum ChannelFixtures {
    static let conflict = "getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"
    static let telegram = ChannelAccountKey(channel: "telegram", accountId: "default")
    static let discord = ChannelAccountKey(channel: "discord", accountId: nil)
    static let whatsapp = ChannelAccountKey(channel: "whatsapp", accountId: "default")

    static let status = Fixtures.json(#"""
    {"ts":1700000000000,"channelOrder":["discord","telegram","whatsapp","slack"],
     "channelLabels":{"discord":"Discord","telegram":"Telegram","whatsapp":"WhatsApp","slack":"Slack"},
     "channelDetailLabels":{"discord":"Discord Bot","telegram":"Telegram Bot","whatsapp":"WhatsApp Web","slack":"Slack App"},
     "channels":{"discord":{"configured":true,"running":true,"connected":true},
                 "telegram":{"configured":true,"running":true,"connected":false,"lastError":"boom"},
                 "whatsapp":{"configured":false,"linked":false},"slack":{"enabled":false,"configured":false}},
     "channelAccounts":{
       "discord":[{"accountId":"default","name":"Discord","enabled":true,"configured":true,"running":true,"connected":true,
                   "lastConnectedAt":1699990000000,"lastInboundAt":1699999000000,"lastOutboundAt":1699999500000,
                   "lastStartAt":1699980000000,"healthState":"healthy","mode":"gateway","lastProbeAt":1700000000000,
                   "probe":{"ok":true,"elapsedMs":38}}],
       "telegram":[{"accountId":"default","name":"Telegram","enabled":true,"configured":true,"running":true,"connected":false,
                    "reconnectAttempts":3,"healthState":"disconnected","mode":"polling",
                    "lastError":"getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"}],
       "whatsapp":[{"accountId":"default","enabled":true,"configured":false,"linked":false,"running":false,"connected":false}],
       "slack":[{"accountId":"default","enabled":false,"configured":false,"running":false,"connected":false}]},
     "channelDefaultAccountId":{"discord":"default","telegram":"default","whatsapp":"default","slack":"default"},
     "partial":true,"warnings":["telegram:default probe timed out after 1000ms"],
     "statusIssues":[{"channel":"whatsapp","accountId":"default","kind":"auth",
                      "message":"Not linked (no WhatsApp Web session).","fix":"Run: openclaw channels login"}]}
    """#)

    static func account(_ fields: String) -> GatewayChannelAccountHealth {
        GatewayChannelAccountHealth(Fixtures.json("{\(fields)}"), fallbackId: "default")
    }
}

/// A stateful fake Gateway for `ChannelsModel` that behaves like `mock-gateway/channels.mjs`:
/// Telegram degraded until stopped and started, WhatsApp logged out, Discord connected. It answers
/// `channels.status` and `health` from the same state and records every call.
@MainActor
final class FakeChannelsGateway {
    var discordRunning = true
    var telegramRunning = true
    var telegramDegraded = true
    var telegramLoggedOut = false
    var whatsappLinked = false
    /// Another bot instance keeps polling, so a fresh start stays degraded.
    var conflictPersists = false
    var calls: [(method: String, params: JSONValue)] = []
    /// Thrown by the method named here instead of answering.
    var failures: [String: GatewayError] = [:]

    var methods: [String] { self.calls.map(\.method) }

    func telegramAccount() -> JSONValue {
        let running = !self.telegramLoggedOut && self.telegramRunning
        let degraded = running && self.telegramDegraded
        var account: [String: JSONValue] = [
            "accountId": "default", "name": "Telegram", "enabled": true, "configured": .bool(!self.telegramLoggedOut),
            "running": .bool(running), "connected": .bool(running && !degraded), "reconnectAttempts": .number(degraded ? 3 : 0),
        ]
        if degraded {
            account["lastError"] = .string(ChannelFixtures.conflict)
            account["healthState"] = "disconnected"
        }
        return .object(account)
    }

    func accounts() -> [String: JSONValue] {
        [
            "discord": ["accountId": "default", "name": "Discord", "enabled": true, "configured": true,
                        "running": .bool(self.discordRunning), "connected": .bool(self.discordRunning)],
            "telegram": self.telegramAccount(),
            "whatsapp": ["accountId": "default", "name": "WhatsApp", "enabled": true, "configured": .bool(self.whatsappLinked),
                         "linked": .bool(self.whatsappLinked), "running": .bool(self.whatsappLinked),
                         "connected": .bool(self.whatsappLinked)],
        ]
    }

    func status(probe: Bool) -> JSONValue {
        var accounts = self.accounts()
        if probe, var telegram = accounts["telegram"]?.object, telegram["configured"]?.bool == true {
            telegram["lastProbeAt"] = 1_700_000_000_000
            telegram["probe"] = self.telegramDegraded
                ? ["ok": false, "error": .string(ChannelFixtures.conflict)] : ["ok": true, "elapsedMs": 38]
            accounts["telegram"] = .object(telegram)
        }
        var result: [String: JSONValue] = [
            "ts": 1_700_000_000_000,
            "channelOrder": ["discord", "telegram", "whatsapp"],
            "channelLabels": ["discord": "Discord", "telegram": "Telegram", "whatsapp": "WhatsApp"],
            "channels": .object(accounts.mapValues { account in
                var summary = account.object ?? [:]
                summary["accountId"] = nil
                return .object(summary)
            }),
            "channelAccounts": .object(accounts.mapValues { .array([$0]) }),
            "channelDefaultAccountId": ["discord": "default", "telegram": "default", "whatsapp": "default"],
        ]
        if !self.whatsappLinked {
            result["statusIssues"] = [["channel": "whatsapp", "accountId": "default", "kind": "auth",
                                       "message": "Not linked (no WhatsApp Web session)."]]
        }
        return .object(result)
    }

    func health() -> JSONValue {
        let accounts = self.accounts()
        return [
            "ok": true, "ts": .number(Date().timeIntervalSince1970 * 1000),
            "channels": .object(accounts.mapValues { account in
                var entry = account.object ?? [:]
                entry["accounts"] = ["default": account]
                return .object(entry)
            }),
            "channelOrder": ["discord", "telegram", "whatsapp"],
            "channelLabels": ["discord": "Discord", "telegram": "Telegram", "whatsapp": "WhatsApp"],
        ]
    }

    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        self.calls.append((method, params))
        if let failure = self.failures[method] { throw failure }
        let channel = params["channel"]?.string ?? ""
        let accountId = params["accountId"]?.string ?? "default"
        func startResult(_ started: Bool, _ status: String, _ reason: String? = nil) -> JSONValue {
            var outcome: [String: JSONValue] = ["status": .string(status)]
            if let reason { outcome["reason"] = .string(reason) }
            return ["channel": .string(channel), "accountId": .string(accountId), "started": .bool(started),
                    "outcome": .object(outcome)]
        }
        switch method {
        case "channels.status":
            return self.status(probe: params["probe"]?.bool == true)
        case "health":
            return self.health()
        case "channels.stop":
            if channel == "telegram" { self.telegramRunning = false }
            if channel == "discord" { self.discordRunning = false }
            return ["channel": .string(channel), "accountId": .string(accountId), "stopped": true]
        case "channels.start":
            switch channel {
            case "telegram":
                if self.telegramLoggedOut { return startResult(false, "skipped", "unconfigured") }
                if self.telegramRunning { return startResult(true, "retry", "task-owned") }
                self.telegramRunning = true
                if !self.conflictPersists { self.telegramDegraded = false }
            case "discord":
                if self.discordRunning { return startResult(true, "retry", "task-owned") }
                self.discordRunning = true
            default:
                if !self.whatsappLinked { return startResult(false, "skipped", "unlinked") }
            }
            return startResult(true, "handed-off")
        case "channels.logout":
            if channel == "discord" {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "channel discord does not support logout", details: nil)
            }
            var cleared = false
            if channel == "telegram" {
                cleared = !self.telegramLoggedOut
                self.telegramLoggedOut = true
            } else if channel == "whatsapp" {
                cleared = self.whatsappLinked
                self.whatsappLinked = false
            }
            return ["channel": .string(channel), "accountId": .string(accountId), "cleared": .bool(cleared),
                    "loggedOut": .bool(cleared)]
        case "web.login.start":
            return ["qrDataUrl": .string(DemoGateway.qrDataUrl(seed: "test")), "message": "Scan this QR in WhatsApp → Linked Devices."]
        case "web.login.wait":
            self.whatsappLinked = true
            return ["connected": true, "message": "✅ Linked! WhatsApp is ready."]
        default:
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
    }

    static let advertised: Set<String> = ["channels.status", "channels.start", "channels.stop", "channels.logout", "health"]

    func model(admin: Bool = true, methods: Set<String>? = FakeChannelsGateway.advertised,
               allowsWritesWithoutAdmin: Bool = false) -> ChannelsModel
    {
        ChannelsModel(methods: { methods },
                      scopes: { admin ? ["operator.read", GatewayConnection.adminScope] : ["operator.read", "operator.write"] },
                      allowsWritesWithoutAdmin: allowsWritesWithoutAdmin) { [unowned self] method, params in
            try self.request(method, params)
        }
    }
}

@Suite struct ChannelStatusParsingTests {
    @Test func parsesChannelsStatus() throws {
        let snapshot = try #require(ChannelsStatusSnapshot(ChannelFixtures.status))
        #expect(snapshot.channels.map(\.id) == ["discord", "telegram", "whatsapp", "slack"])
        #expect(snapshot.channels.map(\.label) == ["Discord", "Telegram", "WhatsApp", "Slack"])
        #expect(snapshot.checkedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.defaultAccountIds["telegram"] == "default")
        #expect(snapshot.detailLabels["whatsapp"] == "WhatsApp Web")
        #expect(snapshot.partial && snapshot.warnings == ["telegram:default probe timed out after 1000ms"])
        #expect(snapshot.issues.map(\.key) == [ChannelFixtures.whatsapp] && snapshot.issues.first?.kind == "auth")
        #expect(snapshot.issues(for: ChannelFixtures.whatsapp).first?.fix == "Run: openclaw channels login")
        #expect(snapshot.issues(for: ChannelFixtures.telegram).isEmpty)

        let discord = try #require(snapshot.account(ChannelFixtures.discord))
        #expect(discord.name == "Discord" && discord.healthState == "healthy" && discord.mode == "gateway")
        #expect(discord.probeOk == true && discord.lastProbeAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(discord.lastStartAt == Date(timeIntervalSince1970: 1_699_980_000))
        #expect(discord.lastActivityAt == Date(timeIntervalSince1970: 1_699_999_500), "latest of inbound and outbound")
        let telegram = try #require(snapshot.account(ChannelFixtures.telegram))
        #expect(telegram.lastError == ChannelFixtures.conflict && telegram.reconnectAttempts == 3 && telegram.lastActivityAt == nil)
        #expect(snapshot.account(ChannelFixtures.whatsapp)?.linked == false)
        #expect(snapshot.account(ChannelAccountKey(channel: "telegram", accountId: "work")) == nil)
        #expect(snapshot.channel("irc") == nil)
    }

    @Test func seededStates() throws {
        let snapshot = try #require(ChannelsStatusSnapshot(ChannelFixtures.status))
        #expect(snapshot.state(of: ChannelFixtures.discord) == .connected)
        #expect(snapshot.state(of: ChannelFixtures.telegram) == .degraded, "running, not connected, last error → Degraded")
        #expect(snapshot.state(of: ChannelFixtures.whatsapp) == .loggedOut)
        #expect(snapshot.state(of: ChannelAccountKey(channel: "slack", accountId: nil)) == .disabled)
        #expect(snapshot.state(of: ChannelAccountKey(channel: "irc", accountId: nil)) == nil)
    }

    @Test func toleratesOddPayloads() throws {
        #expect(ChannelsStatusSnapshot(.array([])) == nil)
        let odd = try #require(ChannelsStatusSnapshot(Fixtures.json(#"""
        {"channelOrder":[1,"matrix"],"channelAccounts":{"matrix":[{"name":"no id"},{"accountId":"a"}],"irc":"nope"},
         "statusIssues":[{"channel":"matrix","message":"hi"},{"kind":"auth"}],"partial":"yes","warnings":[3,"w"]}
        """#)))
        #expect(odd.channels.first?.id == "matrix" && odd.channels.first?.label == "Matrix")
        #expect(odd.account(ChannelAccountKey(channel: "matrix", accountId: "a")) != nil)
        #expect(odd.issues.count == 1 && odd.issues[0].accountId == "default" && odd.issues[0].kind == "runtime")
        #expect(!odd.partial && odd.warnings == ["w"])
        let empty = try #require(ChannelsStatusSnapshot(Fixtures.json(#"{"channelOrder":[],"channelAccounts":{}}"#)))
        #expect(empty.channels.isEmpty && empty.issues.isEmpty)
    }

    @Test func accountKeys() {
        #expect(ChannelFixtures.discord.accountId == "default" && ChannelFixtures.discord.id == "discord/default")
        #expect(ChannelAccountKey(healthIssueId: "channel:telegram:default") == ChannelFixtures.telegram)
        #expect(ChannelAccountKey(healthIssueId: "channel:matrix:ops:east")?.accountId == "ops:east")
        for id in ["plugin:discord", "queue:outbound-prepared-v1", "channel:telegram", "channel::default", "heartbeat:late"] {
            #expect(ChannelAccountKey(healthIssueId: id) == nil, "\(id)")
        }
        let issue = GatewayHealthIssue(id: "channel:telegram:default", kind: .channel, title: "Telegram isn't connected")
        #expect(issue.channelAccount == ChannelFixtures.telegram && issue.offersReconnect)
        #expect(!GatewayHealthIssue(id: "plugin:x", kind: .plugin, title: "x").offersReconnect)
    }
}

@Suite struct ChannelStateTests {
    @Test func stateOrder() {
        let cases: [(String, ChannelAccountState)] = [
            (#""enabled":false,"configured":true,"running":true,"connected":true"#, .disabled),
            (#""enabled":true,"linked":false,"configured":false,"running":false"#, .loggedOut),
            (#""enabled":true,"configured":false,"running":false"#, .notConfigured),
            (#""enabled":true,"configured":true,"running":false,"lastError":"old""#, .stopped),
            (#""enabled":true,"configured":true,"running":true,"connected":false"#, .disconnected),
            (#""configured":true,"running":true,"connected":true,"lastError":"boom""#, .degraded),
            (#""configured":true,"running":true,"connected":true,"healthState":"stale-socket""#, .degraded),
            (#""configured":true,"running":true,"connected":true,"probe":{"ok":false,"error":"401"}"#, .degraded),
            (#""configured":true,"running":true,"connected":true,"healthState":"healthy""#, .connected),
            (#""configured":true,"running":true"#, .running),
            (#""accountId":"x""#, .unknown),
        ]
        for (fields, expected) in cases {
            #expect(ChannelRules.state(of: ChannelFixtures.account(fields)) == expected, "\(fields)")
        }
        let issue = ChannelsStatusSnapshot.Issue(channel: "discord", accountId: "default", kind: "intent", message: "intents", fix: nil)
        #expect(ChannelRules.state(of: ChannelFixtures.account(#""running":true,"connected":true"#), issues: [issue]) == .degraded)
        #expect(ChannelRules.unhealthyHealthStates.isSuperset(of: ["disconnected", "stuck", "stale-socket", "not-running"]))
    }

    @Test func labelsAndAttention() {
        #expect(ChannelAccountState.allCases.map(\.label) == [
            "Connected", "Running", "Degraded", "Disconnected", "Logged Out", "Stopped", "Not Configured", "Disabled", "Unknown",
        ])
        #expect(Set(ChannelAccountState.allCases.filter(\.isHealthy)) == [.connected, .running])
        #expect(Set(ChannelAccountState.allCases.filter(\.needsAttention)) == [.degraded, .disconnected, .stopped, .loggedOut])
        #expect(Set(ChannelAccountState.allCases.map(\.symbol)).count == ChannelAccountState.allCases.count)
    }

    @Test func offeredActions() {
        let running = ChannelFixtures.account(#""configured":true,"running":true,"connected":true"#)
        let stopped = ChannelFixtures.account(#""configured":true,"running":false"#)
        #expect(ChannelRules.offers(.stop, state: .connected, account: running))
        #expect(ChannelRules.offers(.reconnect, state: .degraded, account: running))
        #expect(!ChannelRules.offers(.start, state: .connected, account: running))
        #expect(ChannelRules.offers(.start, state: .stopped, account: stopped))
        #expect(!ChannelRules.offers(.stop, state: .stopped, account: stopped))
        #expect(!ChannelRules.offers(.logout, state: .loggedOut, account: nil))
        #expect(!ChannelRules.offers(.logout, state: .notConfigured, account: nil))
        #expect(!ChannelRules.offers(.reconnect, state: .disabled, account: nil))
        #expect(ChannelRules.supportsQRLogin("whatsapp") && !ChannelRules.supportsQRLogin("telegram"))
    }

    @Test func startOutcomes() {
        #expect(ChannelRules.startProblem(["started": true, "outcome": ["status": "handed-off"]], channelLabel: "Telegram") == nil)
        #expect(ChannelRules.startProblem(["started": true], channelLabel: "Telegram") == nil)
        #expect(ChannelRules.startProblem(["started": false, "outcome": ["status": "skipped", "reason": "unlinked"]],
                                          channelLabel: "WhatsApp")?.hasPrefix("WhatsApp didn't start") == true)
        #expect(ChannelRules.startProblem(["outcome": ["status": "skipped", "reason": "disabled"]], channelLabel: "Slack")
            == "Slack didn't start: the account is disabled.")
        #expect(ChannelRules.startProblem(["outcome": ["status": "skipped", "reason": "autostart-suppressed"]], channelLabel: "X")?
            .contains("autostart") == true)
        #expect(ChannelRules.startProblem(["outcome": ["status": "retry", "reason": "stop-in-flight"]], channelLabel: "X") != nil)
    }

    @MainActor @Test func errorCopy() {
        let scope = GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                     details: ["code": "MISSING_SCOPE", "scope": "operator.admin"])
        #expect(ChannelRules.message(for: scope, action: .stop, channelLabel: "Telegram") == SetupWizardModel.fullManagementMessage)
        let logout = GatewayError.rpc(code: "INVALID_REQUEST", message: "channel discord does not support logout", details: nil)
        #expect(ChannelRules.message(for: logout, action: .logout, channelLabel: "Discord") == "Discord doesn't support logging out.")
        let start = GatewayError.rpc(code: "INVALID_REQUEST", message: "channel irc does not support start", details: nil)
        #expect(ChannelRules.message(for: start, action: .start, channelLabel: "IRC").contains("can't be started"))
        let unknown = GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: channels.stop", details: nil)
        #expect(ChannelRules.message(for: unknown, action: .stop, channelLabel: "Telegram").contains("can't stop"))
        let other = GatewayError.rpc(code: "UNAVAILABLE", message: "Channel telegram changed during logout; retry the request.", details: nil)
        #expect(ChannelRules.message(for: other, action: .logout, channelLabel: "Telegram") == "Channel telegram changed during logout; retry the request.")
    }

    @Test func actionMethods() {
        #expect(ChannelsModel.Action.start.method == "channels.start" && ChannelsModel.Action.stop.method == "channels.stop")
        #expect(ChannelsModel.Action.logout.method == "channels.logout" && ChannelsModel.Action.reconnect.method == nil)
        #expect(ChannelsModel.Action.allCases.map(\.title) == ["Start", "Stop", "Log Out", "Reconnect"])
    }
}

@MainActor
@Suite struct ChannelsModelTests {
    @Test func loadAndProbe() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model()
        #expect(model.supported && !model.hasLoaded && model.state(of: ChannelFixtures.telegram) == .unknown)
        await model.load()
        #expect(model.hasLoaded && model.loadState == .idle && model.snapshot?.channels.count == 3)
        #expect(gateway.calls.first?.params["probe"]?.bool == false)
        #expect(model.state(of: ChannelFixtures.discord) == .connected)
        #expect(model.state(of: ChannelFixtures.telegram) == .degraded)
        #expect(model.state(of: ChannelFixtures.whatsapp) == .loggedOut)
        #expect(model.attentionCount == 2, "Telegram and WhatsApp")
        #expect(model.label(for: ChannelFixtures.telegram) == "Telegram")
        #expect(model.account(ChannelFixtures.telegram)?.probeOk == nil)

        await model.probe()
        let probe = gateway.calls.last?.params
        #expect(probe?["probe"]?.bool == true && probe?["timeoutMs"]?.int == ChannelsModel.probeTimeoutMs)
        #expect(!model.isProbing && model.account(ChannelFixtures.telegram)?.probeOk == false)
        #expect(model.state(of: ChannelFixtures.telegram) == .degraded)
    }

    @Test func unsupportedAndFailingStatus() async {
        let silent = FakeChannelsGateway()
        let hidden = silent.model(methods: ["health", "chat.send"])
        await hidden.load()
        #expect(!hidden.supported && hidden.hasLoaded && silent.calls.isEmpty, "not advertised: nothing is sent")

        let old = FakeChannelsGateway()
        old.failures["channels.status"] = .rpc(code: "UNKNOWN_METHOD", message: "unknown method: channels.status", details: nil)
        let unknown = old.model(methods: nil)
        #expect(unknown.supported)
        await unknown.load()
        #expect(!unknown.supported && unknown.snapshot == nil && unknown.loadState == .idle)

        let broken = FakeChannelsGateway()
        broken.failures["channels.status"] = .rpc(code: "UNAVAILABLE", message: "gateway busy", details: nil)
        let failing = broken.model()
        await failing.load()
        #expect(failing.supported && failing.loadState == .failed("gateway busy") && failing.snapshot == nil)
        broken.failures = [:]
        await failing.refresh()
        #expect(failing.loadState == .idle && failing.snapshot != nil, "Retry recovers")
    }

    @Test func reconnectStopsThenStarts() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model()
        var changed = 0
        model.onChanged = { changed += 1 }
        await model.load()
        #expect(model.canPerform(.reconnect, on: ChannelFixtures.telegram))
        gateway.calls = []
        let ok = await model.reconnect(ChannelFixtures.telegram)
        #expect(ok && changed == 1)
        #expect(gateway.methods == ["channels.stop", "channels.start", "channels.status"])
        let expected: JSONValue = ["channel": "telegram", "accountId": "default"]
        #expect(gateway.calls[0].params == expected && gateway.calls[1].params == expected)
        #expect(model.state(of: ChannelFixtures.telegram) == .connected)
        #expect(model.operation(for: ChannelFixtures.telegram) == nil && !model.isBusy(ChannelFixtures.telegram))
        #expect(model.notice?.isError == false && model.notice?.text.contains("Telegram") == true)
        #expect(model.attentionCount == 1, "only WhatsApp left")
        model.clearNotice()
        #expect(model.notice == nil)
    }

    @Test func stopStartAndLogout() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model()
        await model.load()
        #expect(await model.stop(ChannelFixtures.discord))
        #expect(model.state(of: ChannelFixtures.discord) == .stopped)
        #expect(model.offers(.start, on: ChannelFixtures.discord) && !model.offers(.stop, on: ChannelFixtures.discord))
        #expect(await model.start(ChannelFixtures.discord))
        #expect(model.state(of: ChannelFixtures.discord) == .connected)

        #expect(await model.logout(ChannelFixtures.telegram))
        #expect(model.state(of: ChannelFixtures.telegram) == .notConfigured)
        #expect(!model.offers(.logout, on: ChannelFixtures.telegram))
        // A skipped start is a failure with the reason, not an error thrown.
        let skipped = await model.start(ChannelFixtures.telegram)
        #expect(!skipped && model.notice?.isError == true && model.notice?.text.contains("didn't start") == true)
        #expect(model.operation(for: ChannelFixtures.telegram)?.state.error != nil)
    }

    @Test func unsupportedLogoutFailsWithCopy() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model()
        await model.load()
        let ok = await model.logout(ChannelFixtures.discord)
        #expect(!ok)
        #expect(model.operation(for: ChannelFixtures.discord) == .init(action: .logout, state: .failed("Discord doesn't support logging out.")))
        #expect(model.notice?.isError == true)
        #expect(gateway.methods.last == "channels.status", "reloads after a failure")
        #expect(model.state(of: ChannelFixtures.discord) == .connected)
    }

    @Test func scopeLock() async {
        let gateway = FakeChannelsGateway()
        let reader = gateway.model(admin: false)
        await reader.load()
        #expect(reader.supported && reader.snapshot != nil, "reading needs only operator.read")
        #expect(!reader.canManage)
        #expect(reader.offers(.reconnect, on: ChannelFixtures.telegram), "offered, but locked")
        for action in ChannelsModel.Action.allCases {
            #expect(!reader.canPerform(action, on: ChannelFixtures.telegram), "\(action)")
        }
        #expect(!reader.canLogIn(ChannelFixtures.whatsapp) && reader.offersQRLogin(ChannelFixtures.whatsapp))
        gateway.calls = []
        let ok = await reader.reconnect(ChannelFixtures.telegram)
        #expect(!ok && gateway.calls.isEmpty, "nothing is sent without operator.admin")
        #expect(reader.operation(for: ChannelFixtures.telegram)?.state == .failed(SetupWizardModel.fullManagementMessage))
        reader.startQRLogin(ChannelFixtures.whatsapp)
        #expect(reader.qr.state(channel: "whatsapp", accountId: "default") == .idle && gateway.calls.isEmpty)

        let demo = gateway.model(admin: false, allowsWritesWithoutAdmin: true)
        await demo.load()
        #expect(demo.canManage && demo.canPerform(.reconnect, on: ChannelFixtures.telegram))
        #expect(demo.canLogIn(ChannelFixtures.whatsapp) && !demo.canLogIn(ChannelFixtures.telegram))
    }

    @Test func missingScopeFromGateway() async {
        let gateway = FakeChannelsGateway()
        gateway.failures["channels.stop"] = .rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                                 details: ["code": "MISSING_SCOPE", "scope": "operator.admin"])
        let model = gateway.model()
        await model.load()
        #expect(!(await model.stop(ChannelFixtures.telegram)))
        #expect(model.operation(for: ChannelFixtures.telegram)?.state == .failed(SetupWizardModel.fullManagementMessage))
    }

    @Test func actionsFollowAdvertisedMethods() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model(methods: ["channels.status", "channels.stop"])
        await model.load()
        #expect(model.supports(.stop) && !model.supports(.start) && !model.supports(.reconnect) && !model.supports(.logout))
        #expect(!model.offers(.reconnect, on: ChannelFixtures.telegram) && model.offers(.stop, on: ChannelFixtures.telegram))
        let unknown = gateway.model(methods: nil)
        #expect(ChannelsModel.Action.allCases.allSatisfy(unknown.supports), "unknown method list: assume supported")
    }

    @Test func qrLoginLinksAndRefreshes() async {
        let gateway = FakeChannelsGateway()
        let model = gateway.model()
        var changed = 0
        model.onChanged = { changed += 1 }
        await model.load()
        #expect(model.canLogIn(ChannelFixtures.whatsapp))
        model.startQRLogin(ChannelFixtures.whatsapp)
        for _ in 0..<100 where !(model.state(of: ChannelFixtures.whatsapp) == .connected && changed > 0) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(gateway.methods.contains("web.login.start") && gateway.methods.contains("web.login.wait"))
        #expect(model.state(of: ChannelFixtures.whatsapp) == .connected && changed == 1, "linking reloads status and tells the store")
        if case .connected = model.qr.state(channel: "whatsapp", accountId: "default") {} else {
            Issue.record("QR login ends connected (\(model.qr.state(channel: "whatsapp", accountId: "default")))")
        }
        model.cancelQRLogin(ChannelFixtures.whatsapp)
        #expect(model.qr.state(channel: "whatsapp", accountId: "default") == .idle)
    }

    @Test func resetForgetsEverything() async {
        let gateway = FakeChannelsGateway()
        gateway.failures["channels.logout"] = .rpc(code: "UNAVAILABLE", message: "busy", details: nil)
        let model = gateway.model()
        await model.load()
        _ = await model.logout(ChannelFixtures.telegram)
        #expect(model.operation(for: ChannelFixtures.telegram) != nil)
        model.focusedAccount = ChannelFixtures.telegram
        model.reset()
        #expect(model.snapshot == nil && !model.hasLoaded && model.operations.isEmpty && model.loadState == .idle)
    }

    /// Reconnect Account on Gateway Health: the Telegram issue disappears once `health` reloads, and
    /// its until-changed dismissal is forgotten.
    @Test func reconnectClearsHealthIssue() async {
        let gateway = FakeChannelsGateway()
        let health = GatewayHealthModel(methods: { FakeChannelsGateway.advertised }, scopes: { [GatewayConnection.adminScope] },
                                        dismissals: ["channel:discord:default": "until:state=not-running"]) { method, params in
            try gateway.request(method, params)
        }
        let channels = gateway.model()
        channels.onChanged = { await health.refresh() }
        await health.load()
        let issue = health.activeIssues.first { $0.id == "channel:telegram:default" }
        #expect(issue?.channelAccount == ChannelFixtures.telegram && issue?.offersReconnect == true)
        #expect(!health.activeIssues.contains { $0.id.hasPrefix("channel:whatsapp") }, "logged out WhatsApp isn't configured, so not a Health issue")
        guard let key = issue?.channelAccount else { return }
        #expect(await channels.reconnect(key))
        #expect(!health.issues.contains { $0.id == "channel:telegram:default" })
        #expect(health.health?.channels.first { $0.id == "telegram" }?.status == .connected)
        #expect(health.dismissals["channel:discord:default"] == nil, "a dismissal for a healthy account is pruned")
        // Still failing after a reconnect: the issue stays.
        gateway.conflictPersists = true
        gateway.telegramDegraded = true
        await health.refresh()
        #expect(health.activeIssues.contains { $0.id == "channel:telegram:default" })
        #expect(await channels.reconnect(key))
        #expect(health.activeIssues.contains { $0.id == "channel:telegram:default" }, "still failing: the issue stays")
        #expect(channels.state(of: key) == .degraded)
    }
}

@Suite struct DemoChannelsStateTests {
    @Test func restartStartsStoppedAccountsButNotLoggedOutOnes() {
        var state = DemoChannelsState()
        state.stopped = ["discord", "telegram"]
        state.loggedOut = ["telegram"]
        state.restart(at: 42)
        #expect(state.stopped == ["telegram"], "logged-out Telegram stays down")
        #expect(state.startedAt == ["discord": 42])
    }
}
