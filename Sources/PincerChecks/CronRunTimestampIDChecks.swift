import Foundation
@testable import PincerKit

@MainActor func runCronRunTimestampIDChecks() {
    let source = json(#"{"jobId":"bounds","action":"finished","ts":1e30,"runAtMs":1700000000123,"status":"ok"}"#)
    let first = CronRun(source), second = CronRun(source)
    check(first != nil && first?.id == second?.id && first?.id.isEmpty == false,
          "oversized schema-valid timestamp has a deterministic nonempty fallback ID")
    check(first?.startedAt == Date(timeIntervalSince1970: 1700000000.123) && first?.status == .ok,
          "fallback identity does not change run timing or outcome")
    check(CronRun(json(#"{"jobId":"bounds","ts":1700000000123}"#))?.id == "bounds@1700000000123",
          "ordinary legacy fallback ID stays unchanged")
    check(CronRun(source.applyingMergePatch(["runId": "explicit"]))?.id == "explicit",
          "explicit run ID remains authoritative")
}

@MainActor func runLiveCronRunTimestampIDChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Cron timestamp checks", url: url, authMode: .token)
    profile.secret = token
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("cron timestamp live", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "cron timestamp checks connect to fresh mock"); return
    }
    await gateway.automations.loadRuns(for: "disk-check")
    check(gateway.automations.runs["disk-check"]?.first?.status == .error,
          "actual automation model loads fresh mock cron.runs history")
    do {
        let response = try await gateway.connection.request("cron.runs", ["scope": "job", "id": "disk-check", "limit": 10, "sortDir": "desc"])
        guard let entry = response["entries"]?.array?.first ?? response["runs"]?.array?.first else {
            check(false, "fresh mock supplies actual cron run source"); return
        }
        // Decoder fixture overlay on a real wire entry; never mutate the mock's stored history.
        let oversized = entry.applyingMergePatch(["ts": .number(1e30), "runId": .null, "runAtMs": 1700000000123])
        let run = CronRun(oversized)
        check(run?.jobId == "disk-check" && run?.id.isEmpty == false && run?.id == CronRun(oversized)?.id,
              "real cron.runs entry with explicit oversized decoder overlay preserves identity")
    } catch { check(false, "actual cron.runs timestamp request failed") }
}

@MainActor func runDemoCronRunTimestampIDChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("cron timestamp Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "cron timestamp Demo connects"); return
    }
    await gateway.automations.load()
    check(gateway.automations.hasLoaded && !gateway.automations.supported && gateway.automations.jobs.isEmpty,
          "genuine Demo evaluates its existing unsupported cron capability")
    // Demo has no cron.runs handler. Numeric decoder behavior is the explicit offline fixture.
    runCronRunTimestampIDChecks()
}
