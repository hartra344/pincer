import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway health parsing")
struct GatewayHealthParsingTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static var nowMs: Int { Int(Self.now.timeIntervalSince1970 * 1000) }

    @Test func fullSummary() throws {
        let health = try #require(GatewayHealthSummary(Fixtures.json(#"""
        {"ok":true,"ts":1700000000000,"durationMs":12,"heartbeatSeconds":1800,
         "agents":[{"agentId":"main","heartbeat":{"enabled":true,"every":"30m","everyMs":1800000}}],
         "channelOrder":["discord","slack"],"channelLabels":{"discord":"Discord","slack":"Slack"},
         "channels":{
           "discord":{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true,
                      "lastConnectedAt":1700000000000,"reconnectAttempts":0,"lifecycle":"ready"},
           "slack":{"enabled":false,"configured":false,"running":false,"connected":false}},
         "sessions":{"count":4,"recent":[]},
         "plugins":{"loaded":["discord"],"errors":[],"unavailable":[]},
         "deliveryQueues":{"failed":[]},"contextEngines":{"quarantined":[]},
         "modelPricing":{"state":"degraded"}}
        """#)))
        #expect(health.ok == true && health.durationMs == 12 && health.checkedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(health.channels.map(\.id) == ["discord", "slack"] && health.channels.map(\.label) == ["Discord", "Slack"])
        #expect(health.channels[0].status == .connected && health.channels[1].status == .disabled)
        #expect(health.channels[0].summary.lastConnectedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(health.heartbeatSeconds == 1800 && health.heartbeatEnabled && health.sessionCount == 4)
        #expect(health.modelPricingState == "degraded" && !health.restartPending)
        #expect(GatewayHealthRules.issues(health: health, heartbeat: nil, now: Self.now).isEmpty)
    }

    @Test func emptyAndInvalid() throws {
        let empty = try #require(GatewayHealthSummary(Fixtures.json("{}")))
        #expect(empty.ok == nil && empty.channels.isEmpty && !empty.heartbeatEnabled && empty.heartbeatSeconds == nil)
        #expect(empty.pluginErrors.isEmpty && empty.failedQueues.isEmpty && empty.quarantinedEngines.isEmpty)
        #expect(GatewayHealthSummary(.null) == nil)
        #expect(GatewayHealthSummary(Fixtures.json("[]")) == nil)
        #expect(GatewayHealthSummary("ok") == nil)
    }

    @Test func wrongTypesAreIgnored() throws {
        let health = try #require(GatewayHealthSummary(Fixtures.json(#"""
        {"ok":"yes","ts":"now","channels":{"a":null,"b":[1],"c":{"running":"no","connected":1,"lastError":{"x":1}}},
         "channelOrder":"c","channelLabels":[],"heartbeatSeconds":"1800","agents":{},"plugins":[],
         "deliveryQueues":{"failed":{"q":1}},"contextEngines":null,"sessions":{"count":"4"}}
        """#)))
        #expect(health.ok == nil && health.checkedAt == nil)
        // JSONValue reads numeric strings as numbers.
        #expect(health.heartbeatSeconds == 1800 && health.sessionCount == 4)
        #expect(health.channels.map(\.id) == ["c"] && health.channels[0].label == "C")
        #expect(health.channels[0].problemAccounts.isEmpty && health.channels[0].lastError == nil)
        #expect(health.pluginErrors.isEmpty && health.failedQueues.isEmpty && health.quarantinedEngines.isEmpty)
        // `agents` isn't an array, so the interval decides.
        #expect(health.heartbeatEnabled)
    }

    @Test func heartbeatEnabledFallsBackToInterval() throws {
        #expect(try #require(GatewayHealthSummary(["heartbeatSeconds": 60])).heartbeatEnabled)
        #expect(try #require(GatewayHealthSummary(["heartbeatSeconds": 0])).heartbeatEnabled == false)
        let off = try #require(GatewayHealthSummary(Fixtures.json(
            #"{"heartbeatSeconds":60,"agents":[{"agentId":"main","heartbeat":{"enabled":false}}]}"#)))
        #expect(!off.heartbeatEnabled)
    }

    @Test func channelAccounts() throws {
        let health = try #require(GatewayHealthSummary(Fixtures.json(#"""
        {"channels":{"telegram":{"running":true,"accounts":{
           "b":{"accountId":"bot","name":"Bot","running":true,"connected":false,"restartPending":true},
           "a":{"running":false,"lastError":"boom"},
           "z":"skip"}}}}
        """#)))
        let telegram = health.channels[0]
        #expect(telegram.accounts.map(\.accountId) == ["a", "bot"])
        #expect(telegram.status == .error && telegram.lastError == "boom" && telegram.restartPending && health.restartPending)
        let issues = GatewayHealthRules.issues(health: health, heartbeat: nil, now: Self.now)
        #expect(issues.map(\.id) == ["channel:telegram:a", "channel:telegram:bot"])
        #expect(issues.map(\.title) == ["Telegram (a) isn't running", "Telegram (Bot) isn't connected"])
    }

    @Test func accountProblems() {
        func account(_ text: String) -> GatewayChannelAccountHealth {
            GatewayChannelAccountHealth(Fixtures.json(text), fallbackId: "default")
        }
        #expect(account(#"{"running":false}"#).hasProblem)
        #expect(account(#"{"connected":false}"#).hasProblem)
        #expect(account(#"{"lastError":"x"}"#).hasProblem)
        #expect(!account(#"{"running":true,"connected":true,"lastError":null}"#).hasProblem)
        #expect(!account(#"{"enabled":false,"running":false}"#).hasProblem)
        #expect(!account(#"{"configured":false,"lastError":"x"}"#).hasProblem)
        #expect(account("{}").accountId == "default" && !account("{}").hasProblem)
    }

    @Test func degradedReasons() throws {
        let health = try #require(GatewayHealthSummary(Fixtures.json(#"""
        {"plugins":{"errors":[{"id":"weather","error":"bad manifest"},"memory"],"unavailable":["voice",{"id":"maps"}]},
         "deliveryQueues":{"failed":[{"queueName":"discord","count":3},{"queueName":"ok","count":0}]},
         "contextEngines":{"quarantined":["lossless",{"engineId":"vector"}]}}
        """#)))
        let issues = GatewayHealthRules.issues(health: health, heartbeat: nil, now: Self.now)
        #expect(issues.map(\.kind) == [.plugin, .plugin, .plugin, .plugin, .delivery, .contextEngine, .contextEngine])
        #expect(issues.first?.detail == "bad manifest" && issues[1].detail == "Failed to load")
        #expect(issues[4].title == "3 failed deliveries" && issues[4].detail == "Queue: discord")
        #expect(issues.map(\.id).contains("engine:vector") && issues.map(\.id).contains("plugin-unavailable:maps"))
    }

    @Test func heartbeatParsing() throws {
        let beat = try #require(GatewayHeartbeat(Fixtures.json(#"""
        {"ts":1700000000000,"status":"ok-empty","to":"discord:#home","channel":"discord","durationMs":20,"indicatorType":"ok"}
        """#)))
        #expect(beat.status == .okEmpty && beat.at == Date(timeIntervalSince1970: 1_700_000_000) && !beat.isFailure)
        #expect(beat.to == "discord:#home" && beat.channel == "discord" && beat.durationMs == 20)
        #expect(GatewayHeartbeat(nil) == nil && GatewayHeartbeat(.null) == nil && GatewayHeartbeat("sent") == nil)
        #expect(GatewayHeartbeat(Fixtures.json("{}"))?.status == .other("unknown"))
        #expect(GatewayHeartbeat(["status": "failed"])?.isFailure == true)
        #expect(GatewayHeartbeat(["status": "sent", "indicatorType": "error"])?.isFailure == true)
        #expect(GatewayHeartbeat(["status": "skipped", "indicatorType": "alert"])?.isFailure == false)
        #expect(GatewayHeartbeat.Status("weird").label == "Weird")
    }

    @Test func heartbeatStaleness() {
        func beat(agoSeconds: Int) -> GatewayHeartbeat? {
            GatewayHeartbeat(["ts": .number(Double(Self.nowMs - agoSeconds * 1000)), "status": "sent"])
        }
        #expect(!GatewayHeartbeat.isStale(beat(agoSeconds: 3600), heartbeatSeconds: 1800, enabled: true, now: Self.now))
        #expect(GatewayHeartbeat.isStale(beat(agoSeconds: 3601), heartbeatSeconds: 1800, enabled: true, now: Self.now))
        #expect(!GatewayHeartbeat.isStale(beat(agoSeconds: 9999), heartbeatSeconds: 1800, enabled: false, now: Self.now))
        #expect(!GatewayHeartbeat.isStale(beat(agoSeconds: 9999), heartbeatSeconds: nil, enabled: true, now: Self.now))
        #expect(!GatewayHeartbeat.isStale(nil, heartbeatSeconds: 1800, enabled: true, now: Self.now))
        #expect(!GatewayHeartbeat.isStale(GatewayHeartbeat(["status": "sent"]), heartbeatSeconds: 1800, enabled: true, now: Self.now))

        let health = GatewayHealthSummary(["heartbeatSeconds": 60])
        let issues = GatewayHealthRules.issues(health: health, heartbeat: beat(agoSeconds: 121), now: Self.now)
        #expect(issues.map(\.id) == ["heartbeat:late"] && issues.first?.detail == "Expected every 1 min.")
    }

    @Test func presence() throws {
        let list = GatewayPresenceEntry.list(Fixtures.json(#"""
        [{"host":"Mac","deviceId":"me","clientId":"openclaw-macos","platform":"darwin","deviceFamily":"macOS","mode":"ui",
          "roles":["operator","ui"],"onlineSince":1700000000000,"lastActivityAt":1700000001000,"user":{"name":"Travis"}},
         {"clientId":"cli","ip":"10.0.0.2","roles":"bad"},
         {},
         null,
         {"instanceId":"i1","platform":"linux"},
         {"instanceId":"i1","platform":"linux"}]
        """#))
        #expect(list.count == 4)
        #expect(list[0].displayName == "Travis" && list[0].deviceSummary == "macOS" && list[0].roleSummary == "ui · operator")
        #expect(list[0].onlineSince == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(list[0].isThisDevice(deviceId: "me", instanceId: nil) && !list[0].isThisDevice(deviceId: "other", instanceId: nil))
        #expect(list[1].displayName == "OpenClaw CLI" && list[1].roles.isEmpty && list[1].id == "cli|10.0.0.2")
        #expect(list[2].displayName == "Unknown client" && list[2].id == "presence-2")
        #expect(list[3].isThisDevice(deviceId: nil, instanceId: "i1") && list[3].deviceSummary == "Linux")
        #expect(GatewayPresenceEntry.list(["presence": [["host": "a"]]]).count == 1)
        #expect(GatewayPresenceEntry.list(nil).isEmpty && GatewayPresenceEntry.list("x").isEmpty)
    }

    @Test func restartResult() {
        let deferred = GatewayRestartResult(Fixtures.json(#"""
        {"ok":true,"status":"deferred","preflight":{"safe":false,"counts":{"embeddedRuns":2,"cronRuns":1,"totalActive":3},
         "blockers":[{"message":"2 active agent runs"},{"message":"1 running cron job"}],"summary":"restart deferred"}}
        """#))
        #expect(deferred.status == .deferred && deferred.safe == false && deferred.activeCount == 3)
        #expect(deferred.waitingMessage == "Waiting for 3 active tasks: restart deferred")
        let noSummary = GatewayRestartResult(Fixtures.json(#"{"status":"deferred","preflight":{"blockers":[{"message":"a"},"b"]}}"#))
        #expect(noSummary.activeCount == 2 && noSummary.waitingMessage == "Waiting for 2 active tasks: a; b")
        #expect(GatewayRestartResult(Fixtures.json(#"{"status":"deferred","preflight":{"counts":{"totalActive":-4}}}"#))
            .waitingMessage == "Waiting for 1 active task")
        #expect(GatewayRestartResult(.null).status == .scheduled)
        #expect(GatewayRestartResult(["status": 5]).status == .scheduled)
        #expect(GatewayRestartResult(["status": "coalesced"]).status == .coalesced)
        #expect(GatewayRestartResult(["status": "later"]).status == .other("later"))
    }
}

@Suite("Gateway health level")
struct GatewayHealthLevelTests {
    @Test(arguments: [
        (ConnectionState.connected, false, false, 0, GatewayHealthLevel.healthy),
        (.connected, false, false, 1, .degraded),
        (.connected, false, true, 0, .down),
        (.connected, false, true, 5, .down),
        (.connecting, false, false, 0, .down),
        (.idle, false, false, 3, .down),
        (.reconnecting(attempt: 2, delaySeconds: 4, reason: "closed"), false, false, 0, .down),
        (.failed("nope"), false, false, 0, .down),
        (.connected, true, false, 0, .restarting),
        (.reconnecting(attempt: 1, delaySeconds: 2, reason: "restart"), true, true, 2, .restarting),
    ])
    func mapping(connection: ConnectionState, restarting: Bool, unavailable: Bool, issues: Int, expected: GatewayHealthLevel) {
        #expect(GatewayHealthRules.level(connection: connection, restarting: restarting, healthUnavailable: unavailable,
                                         issueCount: issues) == expected)
    }

    @Test func labelsAndSymbols() {
        #expect([GatewayHealthLevel.healthy, .degraded, .down, .restarting].map(\.label)
            == ["Healthy", "Degraded", "Down", "Restarting"])
        #expect(Set([GatewayHealthLevel.healthy, .degraded, .down, .restarting].map(\.symbol)).count == 4)
    }
}

@MainActor
@Suite("Gateway health model")
struct GatewayHealthModelTests {
    @Test func restartRequiredSetAndClear() {
        let model = GatewayHealthModel { _, _ in .null }
        #expect(!model.needsRestart && model.indicator == nil)
        model.markRestartRequired("Saved. Restart the Gateway to finish applying it.")
        #expect(model.needsRestart && model.indicator == .restartNeeded)
        model.clearRestartRequired()
        #expect(!model.needsRestart && model.indicator == nil)
        model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"discord":{"running":true,"restartPending":true}}}"#))
        #expect(model.needsRestart && model.restartRequiredReason == nil)
    }

    @Test func terminalShutdownIsNotARestart() async {
        let model = GatewayHealthModel(scopes: { [GatewayConnection.adminScope] }) { _, _ in ["status": "scheduled"] }
        model.handle(event: "shutdown", payload: [:])
        model.handle(event: "shutdown", payload: ["restartExpectedMs": .null])
        #expect(model.restartState == .idle && model.indicator == nil)
        model.handle(event: "shutdown", payload: ["restartExpectedMs": 1500])
        #expect(model.restartState == .restarting)
        model.connectionChanged(.connected, hello: nil)
        model.dismissRestartStatus()
        await model.restart()
        model.handle(event: "shutdown", payload: [:])
        #expect(model.restartState == .restarting)
    }

    @Test func staleRestartRequiredClearsOnNewerProcess() {
        let model = GatewayHealthModel { _, _ in .null }
        let now = Date()
        model.markRestartRequired("Saved", at: now.addingTimeInterval(-60))
        model.seed(snapshot: ["uptimeMs": 3_600_000], at: now)
        #expect(model.restartRequiredReason != nil)
        model.seed(snapshot: ["uptimeMs": 5_000], at: now)
        #expect(model.restartRequiredReason == nil)
    }

    @Test func restartRequiredFromOutcomes() {
        #expect(ConfigApplyOutcome.restartRequired.needsManualRestart && ConfigApplyOutcome.savedNotApplied("x").needsManualRestart)
        #expect(!ConfigApplyOutcome.restarting.needsManualRestart && !ConfigApplyOutcome.applied.needsManualRestart)
        #expect(!ConfigApplyOutcome.noChange.needsManualRestart)
    }

    @Test func nonAdminSendsNothing() async {
        var sent: [String] = []
        let model = GatewayHealthModel(scopes: { ["operator.read", "operator.write"] }) { method, _ in
            sent.append(method)
            return .null
        }
        #expect(!model.hasAdmin && !model.canRestart && !model.canForceRestart)
        await model.restart()
        await model.restart(skipDeferral: true)
        #expect(sent.isEmpty && model.restartState == .failed(ConfigWriteError.adminRequired.message))
    }

    @Test func sectionsFollowHelloMethods() async {
        var sent: [String] = []
        let model = GatewayHealthModel(methods: { ["health", "chat.send"] }, scopes: { [GatewayConnection.adminScope] }) { method, _ in
            sent.append(method)
            return [:]
        }
        #expect(model.isAvailable(.health) && !model.isAvailable(.heartbeat) && !model.isAvailable(.presence))
        #expect(!model.isAvailable(.restart) && !model.canRestart)
        await model.load()
        #expect(sent == ["health"])
        let unknown = GatewayHealthModel(methods: { [] }) { _, _ in .null }
        #expect(GatewayHealthModel.Section.allCases.allSatisfy(unknown.isAvailable))
    }

    @Test func forbiddenOrUnknownMarksSectionUnavailable() async {
        let model = GatewayHealthModel(scopes: { [GatewayConnection.adminScope] }) { method, _ in
            switch method {
            case "health": return ["ok": true]
            case "last-heartbeat": throw GatewayError.rpc(code: "FORBIDDEN", message: "not allowed", details: nil)
            case "system-presence": throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
            default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
            }
        }
        await model.load()
        #expect(model.unavailable == [.heartbeat, .presence] && model.isAvailable(.health) && model.health?.ok == true)
        await model.restart()
        #expect(model.unavailable.contains(.restart) && model.restartState == .failed("Restarting isn't available on this Gateway."))
    }

    @Test func missingScopeMessage() {
        let byCode = GatewayError.rpc(code: "MISSING_SCOPE", message: "x", details: nil)
        let byDetails = GatewayError.rpc(code: "FORBIDDEN", message: "x", details: ["code": "MISSING_SCOPE"])
        let byMessage = GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: nil)
        for error in [byCode, byDetails, byMessage] {
            #expect(GatewayHealthModel.message(for: error) == ConfigWriteError.adminRequired.message)
            #expect(!GatewayHealthModel.isUnavailableMethod(error))
        }
    }

    @Test func snapshotSeeding() {
        let model = GatewayHealthModel { _, _ in .null }
        let at = Date(timeIntervalSince1970: 2_000_000)
        model.seed(snapshot: Fixtures.json(#"""
        {"uptimeMs":3600000,"presence":[{"host":"a"}],"health":{"channels":{"discord":{"running":false}}}}
        """#), serverVersion: "2026.2", at: at)
        #expect(model.serverVersion == "2026.2" && model.startedAt == at.addingTimeInterval(-3600))
        #expect(model.uptime(now: at.addingTimeInterval(60)) == 3660 && model.presence.count == 1)
        #expect(model.health?.channels.first?.status == .stopped && model.level(now: at) == .degraded)
        model.seed(snapshot: Fixtures.json(#"{"uptimeMs":-5}"#), at: at)
        #expect(model.uptimeMs == nil && model.startedAt == nil && model.presence.count == 1)
        model.seed(snapshot: nil, at: at)
        #expect(model.uptimeMs == nil && model.uptime() == nil)
    }
}

@Suite("Gateway health dismissals")
struct GatewayHealthDismissalTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func issues(_ text: String, heartbeat: GatewayHeartbeat? = nil) throws -> [GatewayHealthIssue] {
        let health = try #require(GatewayHealthSummary(Fixtures.json(text)))
        return GatewayHealthRules.issues(health: health, heartbeat: heartbeat, now: Self.now)
    }

    static func queue(_ count: Int) throws -> GatewayHealthIssue {
        try #require(Self.issues(#"{"deliveryQueues":{"failed":[{"queueName":"q","count":\#(count)}]}}"#).first)
    }

    @Test func fingerprints() throws {
        let issues = try Self.issues(#"""
        {"heartbeatSeconds":60,
         "channels":{"a":{"running":false},"b":{"running":true,"connected":false},"c":{"lastError":"boom"}},
         "plugins":{"errors":[{"id":"w","error":"bad manifest"}],"unavailable":["v"]},
         "deliveryQueues":{"failed":[{"queueName":"q","count":2}]},"contextEngines":{"quarantined":["e"]}}
        """#, heartbeat: GatewayHeartbeat(["ts": 0, "status": "failed", "reason": "timeout"]))
        let prints = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0.fingerprint) })
        #expect(prints == [
            "channel:a:default": "state=not-running", "channel:b:default": "state=not-connected",
            "channel:c:default": "state=error", "plugin:w": "error=bad manifest", "plugin-unavailable:v": "unavailable",
            "queue:q": "count=2", "engine:e": "quarantined", "heartbeat:failed": "reason=timeout", "heartbeat:late": "every=60",
        ])
        #expect(issues.filter(\.canAlwaysIgnore).map(\.kind).allSatisfy { $0 == .channel || $0 == .plugin })
        #expect(issues.filter(\.canAlwaysIgnore).count == 5)
    }

    @Test func storedValues() {
        #expect(GatewayHealthDismissal(stored: "always") == .always)
        #expect(GatewayHealthDismissal(stored: "until:count=3") == .untilChanged("count=3"))
        #expect(GatewayHealthDismissal(stored: "until:") == .untilChanged(""))
        #expect(GatewayHealthDismissal(stored: "later") == nil && GatewayHealthDismissal(stored: "") == nil)
        for value in [GatewayHealthDismissal.always, .untilChanged("state=error")] {
            #expect(GatewayHealthDismissal(stored: value.stored) == value)
        }
    }

    @Test func queueCountsCompareAsNumbers() throws {
        let dismissedAt1 = GatewayHealthDismissal.untilChanged("count=1")
        #expect(GatewayHealthRules.isDismissed(try Self.queue(1), by: dismissedAt1))
        #expect(!GatewayHealthRules.isDismissed(try Self.queue(2), by: dismissedAt1))
        #expect(!GatewayHealthRules.isDismissed(try Self.queue(3), by: .untilChanged("count=2")))
        #expect(GatewayHealthRules.isDismissed(try Self.queue(2), by: .untilChanged("count=3")))
        #expect(GatewayHealthRules.isDismissed(try Self.queue(10), by: .untilChanged("count=10")))
        #expect(!GatewayHealthRules.isDismissed(try Self.queue(1), by: .always))
        #expect(!GatewayHealthRules.isDismissed(try Self.queue(1), by: nil))
    }

    @Test func channelStateChangeBringsItBack() throws {
        let before = try #require(Self.issues(#"{"channels":{"t":{"running":true,"connected":false,"lastError":"retry 1"}}}"#).first)
        let dismissal = GatewayHealthDismissal.untilChanged(before.fingerprint)
        let newError = try #require(Self.issues(#"{"channels":{"t":{"running":true,"connected":false,"lastError":"retry 2"}}}"#).first)
        #expect(GatewayHealthRules.isDismissed(newError, by: dismissal))
        let stopped = try #require(Self.issues(#"{"channels":{"t":{"running":false,"lastError":"retry 2"}}}"#).first)
        #expect(!GatewayHealthRules.isDismissed(stopped, by: dismissal))
        #expect(GatewayHealthRules.isDismissed(stopped, by: .always))
    }

    @Test func pruningBySource() throws {
        let dismissals = [
            "queue:q": "until:count=1", "channel:t:default": "always", "plugin:w": "until:error=x",
            "heartbeat:late": "until:every=60", "heartbeat:failed": "until:reason=", "engine:e": "garbage",
            "queue:old": "always", "unknown": "until:x",
        ]
        // A fresh `health` without `deliveryQueues` or the plugin: only health-sourced until-changed entries go.
        let pruned = GatewayHealthRules.pruned(dismissals, current: try Self.issues(#"{"ok":true}"#), source: .health)
        #expect(pruned == ["channel:t:default": "always", "heartbeat:late": "until:every=60", "heartbeat:failed": "until:reason=",
                           "unknown": "until:x"])
        // Still reported: kept.
        let kept = GatewayHealthRules.pruned(["queue:q": "until:count=1"], current: [try Self.queue(4)], source: .health)
        #expect(kept == ["queue:q": "until:count=1"])
        // A heartbeat result prunes heartbeat ids only.
        let beat = GatewayHealthRules.pruned(dismissals, current: [], source: .heartbeat)
        #expect(beat["heartbeat:late"] == nil && beat["heartbeat:failed"] == nil && beat["queue:q"] != nil && beat["plugin:w"] != nil)
    }

    @MainActor
    @Test func modelCountsActiveIssuesOnly() async throws {
        let model = GatewayHealthModel(dismissals: ["plugin:gone": "always"]) { _, _ in .null }
        var synced: [[String: String?]] = []
        model.onDismissalsChanged = { synced.append($0) }
        // An empty hello snapshot doesn't prune.
        model.seed(snapshot: ["health": [:]])
        #expect(model.dismissals == ["plugin:gone": "always"] && synced.isEmpty)
        model.handle(event: "health", payload: Fixtures.json(#"""
        {"channels":{"t":{"running":true,"connected":false}},"deliveryQueues":{"failed":[{"queueName":"q","count":1}]}}
        """#))
        #expect(model.level == .degraded && model.indicator == .degraded(issues: 2))
        #expect(model.ignoredButAbsent.map(\.id) == ["plugin:gone"] && model.ignoredButAbsent.first?.title == "Plugin gone")
        let issues = model.activeIssues
        for issue in issues { model.dismiss(issue) }
        #expect(model.level == .healthy && model.indicator == nil && model.activeIssues.isEmpty)
        #expect(model.dismissedIssues.count == 2 && model.issues.count == 2)
        #expect(model.dismissals["queue:q"] == "until:count=1" && model.dismissals["channel:t:default"] == "until:state=not-connected")
        model.dismiss(try #require(issues.first { $0.kind == .delivery }), always: true)
        #expect(model.dismissals["queue:q"] == "until:count=1", "failed deliveries can't be always ignored")
        model.restore(id: "channel:t:default")
        #expect(model.level == .degraded && model.indicator == .degraded(issues: 1))
        #expect(synced.last == ["channel:t:default": String?.none])
        // Down and Restarting don't care about dismissals.
        model.connectionChanged(.reconnecting(attempt: 1, delaySeconds: 1, reason: "x"), hello: nil)
        #expect(model.level == .down && model.indicator == nil && model.ignoredButAbsent.isEmpty)
        model.connectionChanged(.connected, hello: nil)
        // The queue cleared: its entry is pruned and synced; the always entry stays.
        model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"t":{"running":true,"connected":false}}}"#))
        #expect(model.dismissals == ["plugin:gone": "always"] && synced.last == ["queue:q": String?.none])
    }

    @Test func placeholderTitles() {
        #expect(GatewayHealthIssue.placeholder(id: "channel:telegram:default").title == "Telegram (default)")
        #expect(GatewayHealthIssue.placeholder(id: "plugin-unavailable:voice").title == "Plugin voice")
        #expect(GatewayHealthIssue.placeholder(id: "plugin:a:b").kind == .plugin)
    }
}

@MainActor
@Suite("Gateway health dismissal rules and syncing")
struct GatewayHealthDismissalMoreTests {
    static let now = GatewayHealthDismissalTests.now
    static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    static func issue(_ text: String, heartbeat: GatewayHeartbeat? = nil, now: Date = Self.now) throws -> GatewayHealthIssue {
        let health = try #require(GatewayHealthSummary(Fixtures.json(text)))
        return try #require(GatewayHealthRules.issues(health: health, heartbeat: heartbeat, now: now).first)
    }

    @Test func pluginErrorChangeBringsItBack() throws {
        let before = try Self.issue(#"{"plugins":{"errors":[{"id":"w","error":"bad manifest"}]}}"#)
        let dismissal = GatewayHealthDismissal.untilChanged(before.fingerprint)
        #expect(GatewayHealthRules.isDismissed(before, by: dismissal))
        let after = try Self.issue(#"{"plugins":{"errors":[{"id":"w","error":"missing entry point"}]}}"#)
        #expect(!GatewayHealthRules.isDismissed(after, by: dismissal))
        #expect(GatewayHealthRules.isDismissed(after, by: .always) && after.canAlwaysIgnore)
        let unavailable = try Self.issue(#"{"plugins":{"unavailable":["v"]}}"#)
        #expect(GatewayHealthRules.isDismissed(unavailable, by: .untilChanged("unavailable")) && unavailable.canAlwaysIgnore)
    }

    @Test func heartbeatReasonAndIntervalChangesBringItBack() throws {
        let failed = { (reason: String) in
            GatewayHealthRules.issues(health: nil, heartbeat: GatewayHeartbeat(["ts": 0, "status": "failed", "reason": .string(reason)]),
                                      now: Self.now).first { $0.id == "heartbeat:failed" }
        }
        let timeout = try #require(failed("timeout"))
        #expect(GatewayHealthRules.isDismissed(try #require(failed("timeout")), by: .untilChanged(timeout.fingerprint)))
        #expect(!GatewayHealthRules.isDismissed(try #require(failed("model error")), by: .untilChanged(timeout.fingerprint)))
        let noReason = try #require(GatewayHealthRules.issues(health: nil, heartbeat: GatewayHeartbeat(["ts": 0, "status": "failed"]),
                                                              now: Self.now).first)
        #expect(noReason.fingerprint == "reason=")

        let beat = GatewayHeartbeat(["ts": 0, "status": "ok-token"])
        let late60 = try Self.issue(#"{"heartbeatSeconds":60}"#, heartbeat: beat)
        let late120 = try Self.issue(#"{"heartbeatSeconds":120}"#, heartbeat: beat)
        #expect(late60.id == "heartbeat:late" && late120.id == "heartbeat:late")
        #expect(GatewayHealthRules.isDismissed(late60, by: .untilChanged("every=60")))
        #expect(!GatewayHealthRules.isDismissed(late120, by: .untilChanged("every=60")))
        // Later still late: the same interval, so it stays dismissed.
        let later = try Self.issue(#"{"heartbeatSeconds":60}"#, heartbeat: beat, now: Self.now.addingTimeInterval(86_400))
        #expect(GatewayHealthRules.isDismissed(later, by: .untilChanged("every=60")))
    }

    @Test func alwaysOnlyCountsForChannelsAndPlugins() throws {
        let engine = try Self.issue(#"{"contextEngines":{"quarantined":["e"]}}"#)
        let failed = try #require(GatewayHealthRules.issues(health: nil, heartbeat: GatewayHeartbeat(["ts": 0, "status": "failed"]),
                                                            now: Self.now).first)
        for issue in [engine, failed] {
            #expect(!issue.canAlwaysIgnore && !GatewayHealthRules.isDismissed(issue, by: .always))
        }
        #expect(engine.offersRestart && !failed.offersRestart)
        #expect(!(try Self.issue(#"{"deliveryQueues":{"failed":[{"queueName":"q","count":1}]}}"#)).offersRestart)
        // Pruning drops an `always` on an issue that can't be always ignored.
        let pruned = GatewayHealthRules.pruned(["engine:e": "always", "heartbeat:failed": "always", "plugin-unavailable:v": "always"],
                                               current: [], source: .health)
        #expect(pruned == ["heartbeat:failed": "always", "plugin-unavailable:v": "always"])
        #expect(GatewayHealthRules.pruned(pruned, current: [], source: .heartbeat) == ["plugin-unavailable:v": "always"])
    }

    @Test func unknownStoredValuesDontHide() throws {
        let issue = try Self.issue(#"{"channels":{"t":{"running":false}}}"#)
        for stored in ["", "later", "ALWAYS", "until", "state=not-running"] {
            #expect(!GatewayHealthRules.isDismissed(issue, by: GatewayHealthDismissal(stored: stored)), "\(stored)")
        }
        let model = GatewayHealthModel(dismissals: ["channel:t:default": "later"]) { _, _ in .null }
        model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"t":{"running":false}}}"#))
        #expect(model.activeIssues.count == 1 && model.dismissedIssues.isEmpty && model.level == .degraded)
        // Kept while reported, and Restore removes it.
        #expect(model.dismissals == ["channel:t:default": "later"])
        model.restore(id: "channel:t:default")
        #expect(model.dismissals.isEmpty)
    }

    @Test func queueGoingUpThenBackDownStaysActiveUntilPruned() {
        let model = GatewayHealthModel { _, _ in .null }
        let queue = { (count: Int) in
            model.handle(event: "health", payload: Fixtures.json(#"{"deliveryQueues":{"failed":[{"queueName":"q","count":\#(count)}]}}"#))
        }
        queue(3)
        model.dismiss(model.activeIssues[0])
        #expect(model.dismissals == ["queue:q": "until:count=3"] && model.level == .healthy)
        queue(2)
        #expect(model.level == .healthy, "fewer failures stay hidden")
        queue(4)
        #expect(model.level == .degraded && model.dismissals == ["queue:q": "until:count=3"], "stale entry kept, no effect")
        // The queue drained: the entry goes; failures later show as active.
        model.handle(event: "health", payload: Fixtures.json(#"{"ok":true}"#))
        #expect(model.dismissals.isEmpty && model.level == .healthy)
        queue(1)
        #expect(model.level == .degraded)
    }

    @Test func nothingPrunesWithoutAFreshResult() async {
        let dismissals = ["queue:q": "until:count=1", "heartbeat:failed": "until:reason=x", "heartbeat:late": "until:every=60"]
        let model = GatewayHealthModel(dismissals: dismissals) { method, _ in
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "\(method) unavailable", details: nil)
        }
        var synced: [[String: String?]] = []
        model.onDismissalsChanged = { synced.append($0) }
        // Failed / UNAVAILABLE calls, empty payloads and snapshots.
        await model.load()
        model.handle(event: "health", payload: [:])
        model.seed(snapshot: ["health": [:]])
        model.seed(snapshot: ["uptimeMs": 1000])
        #expect(model.dismissals == dismissals && synced.isEmpty)
        // Disconnected: a health event doesn't prune.
        model.connectionChanged(.reconnecting(attempt: 1, delaySeconds: 1, reason: "x"), hello: nil)
        model.handle(event: "health", payload: Fixtures.json(#"{"ok":true}"#))
        model.handle(event: "heartbeat", payload: ["ts": .number(Self.nowMs), "status": "ok-token"])
        #expect(model.dismissals == dismissals && synced.isEmpty)
    }

    @Test func healthAndHeartbeatPruneTheirOwnIds() async {
        let dismissals = ["queue:q": "until:count=1", "heartbeat:failed": "until:reason=x", "channel:t:default": "always"]
        let model = GatewayHealthModel(dismissals: dismissals) { method, _ in
            switch method {
            case "health": return Fixtures.json(#"{"ok":true,"heartbeatSeconds":1800}"#)
            case "last-heartbeat": return ["ts": .number(Date().timeIntervalSince1970 * 1000), "status": "ok-token"]
            default: return .array([])
            }
        }
        model.handle(event: "heartbeat", payload: ["ts": .number(Self.nowMs), "status": "ok-token"])
        #expect(model.dismissals == ["queue:q": "until:count=1", "channel:t:default": "always"])
        model.seed(snapshot: ["health": Fixtures.json(#"{"ok":true}"#)])
        #expect(model.dismissals == ["channel:t:default": "always"])
        #expect(model.ignoredButAbsent.map(\.title) == ["T (default)"])
        await model.load()
        #expect(model.dismissals == ["channel:t:default": "always"])
    }

    @Test func heartbeatBeforeHealthKeepsLateDismissal() {
        let model = GatewayHealthModel(dismissals: ["heartbeat:late": "until:every=60"]) { _, _ in .null }
        model.handle(event: "heartbeat", payload: ["ts": 0, "status": "ok-token"])
        #expect(model.dismissals == ["heartbeat:late": "until:every=60"], "no health yet, so late can't be judged")
        model.handle(event: "health", payload: Fixtures.json(#"{"heartbeatSeconds":60}"#))
        #expect(model.dismissedIssues.map(\.id) == ["heartbeat:late"] && model.level == .healthy)
        model.handle(event: "heartbeat", payload: ["ts": .number(Self.nowMs), "status": "ok-token"])
        #expect(model.dismissals.isEmpty && model.level == .healthy)
    }

    @Test func restartingIgnoresDismissals() {
        let model = GatewayHealthModel(scopes: { [GatewayConnection.adminScope] }) { _, _ in .null }
        model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"t":{"running":false}}}"#))
        model.dismiss(model.activeIssues[0])
        #expect(model.level == .healthy)
        model.handle(event: "shutdown", payload: ["restartExpectedMs": 1500])
        #expect(model.level == .restarting && model.restartState == .restarting)
        model.connectionChanged(.reconnecting(attempt: 1, delaySeconds: 1, reason: "x"), hello: nil)
        #expect(model.level == .restarting && model.issues.isEmpty && model.activeIssues.isEmpty && model.dismissedIssues.isEmpty)
    }

    @Test func noDismissalsLeavesBehaviorUnchanged() {
        let model = GatewayHealthModel { _, _ in .null }
        model.handle(event: "health", payload: Fixtures.json(#"{"channels":{"t":{"running":false}},"contextEngines":{"quarantined":["e"]}}"#))
        #expect(model.activeIssues == model.issues && model.dismissedIssues.isEmpty && model.ignoredButAbsent.isEmpty)
        #expect(model.level == .degraded && model.indicator == .degraded(issues: 2))
    }

    @Test func storeKeepsDismissalsInDefaultsAndTheModel() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Health", url: "ws://127.0.0.1:9", authMode: .none)
        let store = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        let key = "pincer.healthDismissals.\(profile.id.uuidString)"
        store.health.dismiss(GatewayHealthIssue(id: "queue:q", kind: .delivery, title: "1 failed delivery", fingerprint: "count=1"))
        #expect(store.healthDismissals == ["queue:q": "until:count=1"])
        #expect(scratch.defaults.dictionary(forKey: key) as? [String: String] == ["queue:q": "until:count=1"])
        // A pull (another device) updates the model too.
        store.healthDismissals = ["plugin:w": "always"]
        #expect(store.health.dismissals == ["plugin:w": "always"])
        // A relaunch reads the local copy.
        let relaunched = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        #expect(relaunched.healthDismissals == ["plugin:w": "always"] && relaunched.health.dismissals == ["plugin:w": "always"])
        store.health.restore(id: "plugin:w")
        #expect(store.healthDismissals.isEmpty && scratch.defaults.dictionary(forKey: key) as? [String: String] == [:])
    }

    @Test func removingAGatewayForgetsLocalDismissals() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let store = app.add(GatewayProfile(name: "Health", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        let id = store.id.uuidString
        store.healthDismissals = ["channel:t:default": "always"]
        scratch.defaults.set(true, forKey: "pincer.healthDismissalsSynced.\(id)")
        #expect(scratch.defaults.dictionary(forKey: "pincer.healthDismissals.\(id)") != nil)
        app.remove(store.id)
        #expect(scratch.defaults.object(forKey: "pincer.healthDismissals.\(id)") == nil)
        #expect(scratch.defaults.object(forKey: "pincer.healthDismissalsSynced.\(id)") == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(scratch.defaults.object(forKey: "pincer.healthDismissals.\(id)") == nil)
    }
}
