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
