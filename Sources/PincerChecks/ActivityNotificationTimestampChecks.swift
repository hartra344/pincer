import Foundation
@testable import PincerKit

@MainActor private func checkActivityTimestamp(_ source: JSONValue) {
    // Explicit decoder fixture overlay: unread is LOCAL state, never a Gateway row field claim.
    guard let row = SessionRow(source.applyingMergePatch(["updatedAt": .number(1e30), "unread": true])) else {
        check(false, "actual session source parses with the timestamp fixture overlay"); return
    }
    let result = BackgroundRefreshPlanner.plan(snapshot: .init(sessions: [row]),
        cursor: .init(activityMs: 1000, approvalIds: [], questionIds: []), filter: .init(),
        gatewayId: UUID(), gatewayName: "Fixture")
    check(result.requests.count == 1 && result.requests.first?.identifier == "reply:\(row.key):\(String(1e30))",
          "actual activity planner safely builds the oversized timestamp identity")
    check(result.cursor.activityMs == 1e30, "activity cursor retains the actual numeric metadata")
}

@MainActor func runActivityNotificationTimestampChecks() {
    checkActivityTimestamp(["key": "agent:main:dashboard:timestamp"])
    check(ActivityNotificationIdentity.make(key: "k", activityMs: 123.9) == "reply:k:123",
          "ordinary activity notification IDs retain truncating compatibility")
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    guard let row = SessionRow(["key": "agent:main:dashboard:timestamp", "updatedAt": .number(1e30)]) else {
        check(false, "actual notification row parses"); return
    }
    let notifier = Notifier()
    // Integration-only: post reads the existing shared enabled preference, never writes it.
    // Push deferral exits before cursor writes or notification-center admission.
    notifier.appIsActive = false
    notifier.pushDelivers = { _ in true }
    notifier.notifyActivity(row: row, gateway: gateway)
    check(true, "actual activity notification path accepts oversized identity without posting")
}

@MainActor func runDemoActivityNotificationTimestampChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("activity timestamp Demo", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "activity timestamp checks connect to the genuine Demo")
    guard connected else { return }
    do {
        let response = try await gateway.connection.request("sessions.list", [:])
        guard let row = response["sessions"]?.array?.first else {
            check(false, "actual Demo sessions.list supplies the planner source"); return
        }
        checkActivityTimestamp(row)
    } catch { check(false, "actual Demo sessions.list failed") }
}
