import Foundation
@testable import PincerKit

@MainActor private func checkBackgroundRefreshOverflow(_ rows: [SessionRow], gatewayId: UUID) {
    let snapshot = BackgroundRefreshSnapshot(sessions: rows)
    let result = BackgroundRefreshPlanner.plan(snapshot: snapshot,
        cursor: .init(activityMs: 0, approvalIds: [], questionIds: []), filter: .init(showAutomations: true, showSlashCommands: true),
        gatewayId: gatewayId, gatewayName: "Home")
    check(result.requests.count == 11, "eleven eligible chats produce ten replies and one overflow summary")
    check(result.requests.filter { $0.identifier.hasPrefix("reply:") }.count == 10, "individual reply cap stays ten")
    check(result.cursor.activityMs == rows.map(\.activityMs).max(), "cursor still advances past all eligible chats")
    check(BackgroundRefreshPlanner.plan(snapshot: snapshot, cursor: result.cursor, filter: .init(),
        gatewayId: gatewayId, gatewayName: "Home").requests.isEmpty, "unchanged second refresh does not repeat notifications")
}
@MainActor func runBackgroundRefreshOverflowChecks() {
    let rows = (0..<11).map { index in
        SessionRow(.object(["key": .string("agent:main:dashboard:overflow-\(index)"), "unread": true,
            "lastActivityAt": .number(Double(2000 + index)), "hasActiveRun": false]))!
    }
    checkBackgroundRefreshOverflow(rows, gatewayId: UUID())
}
@MainActor func runDemoBackgroundRefreshOverflowChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("background summary Demo", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped && gateway.sessions.count >= 11
    }
    check(ready, "actual Demo is connected with a nonempty session inventory"); guard ready else { return }
    let filter = BackgroundRefreshFilter(showAutomations: true, showSlashCommands: true)
    let source = gateway.sessions.values.filter { filter.notifies($0) && !$0.hasActiveRun && $0.activityMs > 0 }
        .sorted { $0.key < $1.key }.prefix(11)
    check(source.count == 11, "actual Demo supplies eleven eligible distinct chats"); guard source.count == 11 else { return }
    // Explicit local unread-state input; actual session identities, activity and previews remain unchanged.
    // This exercises the shipped planner, not OS scheduling or notification delivery.
    let rows = source.compactMap { row -> SessionRow? in
        guard var raw = row.raw.object else { return nil }; raw["unread"] = true
        return SessionRow(.object(raw))
    }
    check(rows.count == 11 && Set(rows.map(\.key)).count == 11, "full actual session inventory survives local unread projection")
    guard rows.count == 11 else { return }
    checkBackgroundRefreshOverflow(rows, gatewayId: gateway.id)
}
