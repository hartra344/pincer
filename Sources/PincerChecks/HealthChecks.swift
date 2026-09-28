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

/// `GatewayHealthModel` and its parsing, offline.
@MainActor
func checkGatewayHealth() async {
    print("Gateway health")
    let now = Date(timeIntervalSince1970: 1_000_000)
    let nowMs = Int(now.timeIntervalSince1970 * 1000)

    // Tolerant parsing: `{}`, wrong types and nulls don't crash or invent problems.
    let empty = GatewayHealthSummary(json("{}"))
    check(empty != nil && empty?.channels.isEmpty == true && empty?.heartbeatEnabled == false && empty?.ok == nil,
          "empty health parses to nothing")
    check(GatewayHealthSummary(json("[]")) == nil && GatewayHealthSummary(.null) == nil, "non-object health rejected")
    let messy = GatewayHealthSummary(json(#"""
    {"ok":"yes","ts":null,"channels":{"discord":{"connected":"true","running":null},"bad":5,"x":{"accounts":{"a":7}}},
     "channelOrder":[1,"discord"],"heartbeatSeconds":"30","agents":"nope","plugins":{"errors":[{"id":"p1"},3]},
     "deliveryQueues":{"failed":[{"queueName":"q","count":0},{"count":2}]},"contextEngines":{"quarantined":["lossless"]}}
    """#))
    check(messy?.ok == nil && messy?.channels.map(\.id) == ["discord", "x"] && messy?.channels.first?.problemAccounts.isEmpty == true,
          "wrong-typed fields ignored, non-object channels skipped")
    check(messy?.pluginErrors.map(\.id) == ["p1"] && messy?.pluginErrors.first?.error == "Failed to load" && messy?.failedQueues.map(\.count) == [2]
          && messy?.failedQueues.first?.queueName == "delivery" && messy?.quarantinedEngines == ["lossless"],
          "plugin errors, failed queues (count > 0) and quarantined engines")

    // Channel status and issues.
    let health = GatewayHealthSummary(json(#"""
    {"ok":true,"heartbeatSeconds":1800,"agents":[{"agentId":"main","heartbeat":{"enabled":true}}],
     "channelOrder":["telegram","discord"],"channelLabels":{"discord":"Discord","telegram":"Telegram"},
     "channels":{
       "discord":{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true},
       "telegram":{"accounts":{"bot":{"accountId":"bot","running":true,"connected":false,"lastError":"401 Unauthorized"},
                               "old":{"enabled":false,"running":false}}},
       "slack":{"enabled":false,"configured":false,"running":false},
       "signal":{"configured":false},
       "matrix":{"running":true,"restartPending":true}}}
    """#))!
    check(health.channels.map(\.id) == ["telegram", "discord", "matrix", "signal", "slack"], "channelOrder first, then the rest sorted")
    let status = Dictionary(uniqueKeysWithValues: health.channels.map { ($0.id, $0.status) })
    check(status["discord"] == .connected && status["telegram"] == .error && status["slack"] == .disabled
          && status["signal"] == .notConfigured && status["matrix"] == .running, "channel statuses")
    check(health.restartPending && health.heartbeatEnabled && health.channels[0].lastError == "401 Unauthorized",
          "restartPending, heartbeat enabled, last error")
    let issues = GatewayHealthRules.issues(health: health, heartbeat: nil, now: now)
    check(issues.map(\.id) == ["channel:telegram:bot"] && issues.first?.title == "Telegram (bot) isn't connected"
          && issues.first?.detail == "401 Unauthorized", "only the active broken account is an issue")
    check(GatewayChannelAccountHealth(json(#"{"connected":false,"enabled":false}"#), fallbackId: "d").hasProblem == false
          && GatewayChannelAccountHealth(json(#"{"running":false}"#), fallbackId: "d").hasProblem
          && GatewayChannelAccountHealth(json(#"{"connected":false,"configured":false}"#), fallbackId: "d").hasProblem == false,
          "disabled or unconfigured accounts don't count")

    // Heartbeats.
    let fresh = GatewayHeartbeat(json(#"{"ts":\#(nowMs - 1_000_000),"status":"ok-token"}"#))
    let late = GatewayHeartbeat(json(#"{"ts":\#(nowMs - 4_000_000),"status":"sent"}"#))
    let failed = GatewayHeartbeat(json(#"{"ts":\#(nowMs),"status":"failed","reason":"timeout"}"#))
    check(GatewayHeartbeat(.null) == nil && GatewayHeartbeat(nil) == nil && GatewayHeartbeat(json(#"{"status":5}"#))?.status == .other("unknown"),
          "null heartbeat is none; bad status tolerated")
    check(!GatewayHeartbeat.isStale(fresh, heartbeatSeconds: 1800, enabled: true, now: now)
          && GatewayHeartbeat.isStale(late, heartbeatSeconds: 1800, enabled: true, now: now)
          && !GatewayHeartbeat.isStale(late, heartbeatSeconds: 1800, enabled: false, now: now)
          && !GatewayHeartbeat.isStale(late, heartbeatSeconds: 0, enabled: true, now: now)
          && !GatewayHeartbeat.isStale(nil, heartbeatSeconds: 1800, enabled: true, now: now),
          "stale only past 2x the interval while heartbeats are on")
    let quiet = GatewayHealthSummary(json(#"{"heartbeatSeconds":1800}"#))
    check(GatewayHealthRules.issues(health: quiet, heartbeat: late, now: now).map(\.kind) == [.heartbeat]
          && GatewayHealthRules.issues(health: quiet, heartbeat: failed, now: now).first?.detail == "timeout"
          && GatewayHealthRules.issues(health: quiet, heartbeat: fresh, now: now).isEmpty, "late and failed heartbeats are issues")

    // Level mapping.
    check(GatewayHealthRules.level(connection: .connected, restarting: false, healthUnavailable: false, issueCount: 0) == .healthy
          && GatewayHealthRules.level(connection: .connected, restarting: false, healthUnavailable: false, issueCount: 2) == .degraded
          && GatewayHealthRules.level(connection: .connected, restarting: false, healthUnavailable: true, issueCount: 0) == .down
          && GatewayHealthRules.level(connection: .reconnecting(attempt: 1, delaySeconds: 2, reason: "x"), restarting: false,
                                      healthUnavailable: false, issueCount: 0) == .down
          && GatewayHealthRules.level(connection: .idle, restarting: true, healthUnavailable: false, issueCount: 3) == .restarting,
          "levels: healthy, degraded, down, restarting wins")

    // Presence.
    let presence = GatewayPresenceEntry.list(json(#"""
    [{"host":"Mac","deviceId":"me","clientId":"openclaw-macos","platform":"macos","deviceFamily":"Mac","mode":"ui","roles":["operator"],"lastActivityAt":1},
     {"clientId":"openclaw-control-ui","instanceId":"web-1","lastActivityAt":5000},
     {"host":"pi","mode":"node","roles":["node"]}, 3, {"host":"Mac","deviceId":"me","clientId":"openclaw-macos"}]
    """#))
    check(presence.count == 3 && presence[1].displayName == "Control UI" && presence[0].deviceSummary == "macOS · Mac"
          && presence[0].roleSummary == "ui · operator", "presence parses, duplicates and non-objects dropped")
    check(GatewayPresenceEntry.list(json(#"{"presence":[{"host":"a"}]}"#)).count == 1 && GatewayPresenceEntry.list(.null).isEmpty,
          "presence event wrapper and null")

    // Restart result.
    let deferred = GatewayRestartResult(json(#"""
    {"status":"deferred","preflight":{"safe":false,"counts":{"totalActive":2},"blockers":[{"message":"1 active agent run"}],"summary":"restart deferred: 1 active agent run"}}
    """#))
    check(deferred.status == .deferred && deferred.safe == false && deferred.activeCount == 2
          && deferred.waitingMessage == "Waiting for 2 active tasks: restart deferred: 1 active agent run", "deferred restart result")
    let summed = GatewayRestartResult(json(#"{"status":"deferred","preflight":{"counts":{"embeddedRuns":1,"cronRuns":"x","queueSize":0}}}"#))
    check(summed.activeCount == 1 && summed.waitingMessage == "Waiting for 1 active task"
          && GatewayRestartResult(json("{}")).status == .scheduled && GatewayRestartResult(json(#"{"status":"coalesced"}"#)).status == .coalesced,
          "counts summed without totalActive; missing status is scheduled")

    // The model: sections, seeding, restart states.
    let admin = [GatewayConnection.adminScope]
    var sent: [(String, JSONValue)] = []
    /// What the scripted Gateway answers to `gateway.restart.request`; a reference so the request closure sees changes.
    final class RestartReply {
        var next: () throws -> JSONValue = { json(#"{"status":"scheduled"}"#) }
    }
    let restartReply = RestartReply()
    let model = GatewayHealthModel(methods: { ["health", "last-heartbeat", "system-presence", "gateway.restart.request"] },
                                   scopes: { admin }, localDeviceId: "me") { method, params in
        sent.append((method, params))
        switch method {
        case "health": return json(#"{"channels":{"telegram":{"connected":false}},"heartbeatSeconds":0}"#)
        case "last-heartbeat": return .null
        case "system-presence": return presence.isEmpty ? [] : json(#"[{"host":"pi"},{"host":"Mac","deviceId":"me","lastActivityAt":1}]"#)
        case "gateway.restart.request": return try restartReply.next()
        default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
    }
    model.notBackAfter = .milliseconds(1600)
    model.seed(snapshot: json(#"{"uptimeMs":90000,"health":{},"presence":"bad"}"#), serverVersion: "2026.1", at: now)
    check(model.uptimeMs == 90000 && model.startedAt == now.addingTimeInterval(-90) && model.health == nil
          && model.serverVersion == "2026.1", "hello snapshot: uptime anchored, empty health not stored")
    await model.load()
    check(model.hasLoaded && model.level == .degraded && model.issues.count == 1 && model.heartbeat == nil && model.heartbeatLoaded
          && Set(sent.map(\.0)) == ["health", "last-heartbeat", "system-presence"], "load reads three sections, degraded by a channel")
    check(model.sortedPresence.first?.deviceId == "me" && model.isThisDevice(model.sortedPresence[0]) && model.indicator == .degraded(issues: 1),
          "this device first; indicator shows degraded")
    sent = []
    await model.refresh()
    check(Set(sent.map(\.0)) == ["health", "last-heartbeat"], "refresh skips presence")

    check(model.canRestart && !model.canForceRestart, "admin can restart")
    sent = []
    await model.restart()
    check(sent.first?.0 == "gateway.restart.request" && sent.first?.1["reason"]?.string == GatewayHealthModel.restartReason
          && sent.first?.1["skipDeferral"] == nil && model.restartState == .scheduled(coalesced: false) && model.level == .restarting,
          "scheduled restart, reason sent, no skipDeferral")
    model.handle(event: "shutdown", payload: json(#"{"reason":"restart","restartExpectedMs":1000}"#))
    model.connectionChanged(.reconnecting(attempt: 1, delaySeconds: 1, reason: "closed"), hello: nil)
    check(model.restartState == .restarting && model.indicator == .restarting, "shutdown: restarting")
    let reconnecting = await waitFor("reconnecting after expected ms", timeout: 3) { model.restartState == .reconnecting }
    check(reconnecting, "reconnecting after restartExpectedMs")
    let notBack = await waitFor("not back after the limit", timeout: 3) { model.restartState == .notBack }
    check(notBack, "not back after the limit")
    check(model.indicator == .notBack && model.restartState.message == "Gateway hasn't come back yet", "not back message")
    model.markRestartRequired("Saved")
    var restartedCalled = false
    model.onRestarted = { restartedCalled = true }
    model.connectionChanged(.connected, hello: nil)
    check(model.restartState == .restarted(uptimeMs: 90000) && model.restartRequiredReason == nil && restartedCalled,
          "reconnect: restarted, restart-required cleared, callback")
    model.dismissRestartStatus()
    check(model.restartState == .idle, "dismiss restarted status")

    restartReply.next = { json(#"{"status":"deferred","preflight":{"safe":false,"counts":{"totalActive":1},"summary":"1 run"}}"#) }
    await model.restart()
    check(model.restartState == .waiting("Waiting for 1 active task: 1 run") && model.canForceRestart && !model.canRestart,
          "deferred: waiting, force offered")
    restartReply.next = { json(#"{"status":"coalesced"}"#) }
    sent = []
    await model.restart(skipDeferral: true)
    check(sent.first?.1["skipDeferral"]?.bool == true && model.restartState == .scheduled(coalesced: false)
          && model.restartState.message == "Restarting…", "force sends skipDeferral: true; coalesced reads Restarting…")
    model.connectionChanged(.connecting, hello: nil)
    check(model.restartState == .restarting, "losing the socket while scheduled means restarting")
    model.connectionChanged(.connected, hello: nil)
    check(model.restartState == .restarted(uptimeMs: 90000), "back after scheduled")

    for (code, details, expected) in [
        ("RATE_LIMITED", JSONValue?.none, "The Gateway limits how often it restarts. Try again in a minute."),
        ("FORBIDDEN", json(#"{"code":"MISSING_SCOPE"}"#), ConfigWriteError.adminRequired.message),
        ("INVALID_REQUEST", nil, "The Gateway refused the restart: bad reason"),
    ] {
        restartReply.next = { throw GatewayError.rpc(code: code, message: "bad reason", details: details) }
        model.dismissRestartStatus()
        await model.restart()
        check(model.restartState == .failed(expected), "restart error \(code)")
    }
    restartReply.next = { throw GatewayError.closed("gone") }
    model.dismissRestartStatus()
    await model.restart()
    check(model.restartState == .restarting, "socket closed mid-request means restarting")
    model.connectionChanged(.connected, hello: nil)

    // Not admin: nothing sent.
    var readerSent: [String] = []
    let reader = GatewayHealthModel(scopes: { ["operator.read"] }) { method, params in
        readerSent.append(method)
        _ = params
        throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
    }
    check(!reader.canRestart && !reader.hasAdmin, "non-admin can't restart")
    await reader.restart()
    check(readerSent.isEmpty && reader.restartState == .failed(ConfigWriteError.adminRequired.message), "non-admin restart sends nothing")
    await reader.load()
    check(reader.unavailable == [.health, .heartbeat, .presence] && !reader.isAvailable(.health) && reader.level == .healthy,
          "UNKNOWN_METHOD marks sections unavailable")
    readerSent = []
    await reader.load()
    check(readerSent.isEmpty, "unavailable sections aren't asked again")

    let old = GatewayHealthModel(methods: { ["chat.send"] }, scopes: { admin }) { _, _ in .null }
    check(!old.isAvailable(.restart) && !old.canRestart && old.isAvailable(.restart) == false, "method missing from hello: no restart")
    let down = GatewayHealthModel(scopes: { admin }) { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "probe failed", details: nil) }
    await down.load()
    check(down.healthFailure == "probe failed" && down.level == .down, "health UNAVAILABLE is down")
    down.connectionChanged(.reconnecting(attempt: 1, delaySeconds: 2, reason: "x"), hello: nil)
    check(down.level == .down && down.issues.isEmpty && down.indicator == nil, "disconnected: down, no issues, no indicator")

    // Events.
    let events = GatewayHealthModel { _, _ in .null }
    events.handle(event: "health", payload: json(#"{"channels":{"discord":{"running":false}}}"#))
    events.handle(event: "heartbeat", payload: json(#"{"ts":\#(nowMs),"status":"failed"}"#))
    events.handle(event: "presence", payload: json(#"{"presence":[{"host":"a"},{"host":"b"}]}"#))
    events.handle(event: "presence", payload: json(#"{"nope":1}"#))
    check(events.health?.channels.first?.status == .stopped && events.heartbeat?.isFailure == true && events.presence.count == 2,
          "health, heartbeat and presence events")
    events.markRestartRequired("x")
    check(events.needsRestart && events.indicator == .restartNeeded, "restart required indicator")

    // A terminal `shutdown` (no numeric restartExpectedMs) isn't a restart unless this device asked for one.
    for payload in [json("{}"), json(#"{"reason":"stop","restartExpectedMs":null}"#), json(#"{"restartExpectedMs":"1500"}"#)] {
        events.handle(event: "shutdown", payload: payload)
        check(events.restartState == .idle && events.indicator == .restartNeeded, "terminal shutdown leaves restart state alone (\(payload))")
    }
    check(GatewayHealthModel.restartExpectedMs(shutdown: json(#"{"restartExpectedMs":1500}"#)) == 1500
          && GatewayHealthModel.restartExpectedMs(shutdown: json(#"{"restartExpectedMs":-1}"#)) == nil, "restartExpectedMs must be a number")
    events.handle(event: "shutdown", payload: json(#"{"restartExpectedMs":1500}"#))
    check(events.restartState == .restarting, "shutdown with restartExpectedMs is a restart, even from elsewhere")
    events.connectionChanged(.connected, hello: nil)
    let asked = GatewayHealthModel(scopes: { admin }) { _, _ in json(#"{"status":"scheduled"}"#) }
    await asked.restart()
    asked.handle(event: "shutdown", payload: json("{}"))
    check(asked.restartState == .restarting, "shutdown without restartExpectedMs after our own request is our restart")

    // Restarted elsewhere since the change was saved: the flag clears on the next hello.
    let stale = GatewayHealthModel { _, _ in .null }
    stale.markRestartRequired("Saved", at: now.addingTimeInterval(-120))
    stale.seed(snapshot: json(#"{"uptimeMs":600000}"#), at: now)
    check(stale.restartRequiredReason != nil, "older process keeps restart-required")
    stale.seed(snapshot: json(#"{"uptimeMs":30000}"#), at: now)
    check(stale.restartRequiredReason == nil && !stale.needsRestart, "newer process clears restart-required")
}
