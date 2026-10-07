import Foundation
@testable import PincerKit

@MainActor private func checkRecordedActions(request: (JSONValue) async throws -> JSONValue, records: () async -> [JSONValue]) async {
    let before = await records()
    let identity = UUID().uuidString
    let add: JSONValue = ["channel": "discord", "action": "react", "idempotencyKey": .string(identity + "-add"),
        "params": ["messageId": "demo-main-status", "emoji": "🎉", "remove": false]]
    let remove: JSONValue = ["channel": "discord", "action": "react", "idempotencyKey": .string(identity + "-remove"),
        "params": ["messageId": "demo-main-status", "emoji": "🎉", "remove": true]]
    do {
        let first = try await request(add), replay = try await request(add), second = try await request(remove)
        check(first == replay && first == ["ok": true, "added": "🎉"], "accepted action replay returns exact original result")
        check(second == ["ok": true, "removed": "🎉"], "second accepted action returns exact removal result")
        let after = await records()
        check(Array(after.dropFirst(before.count)) == [add, remove], "recording preserves full accepted params in order without replay duplication")
    } catch { check(false, "actual Demo action recording requests complete") }
}
@MainActor func runDemoActionRecordingChecks() async {
    let demo = DemoGateway()
    await checkRecordedActions(request: { try await demo.handle("message.action", $0) }, records: { await demo.recordedActions })
}
@MainActor func runConnectedDemoActionRecordingChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("Demo recorded actions", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo action connection is ready"); guard ready else { return }
    await checkRecordedActions(request: { try await gateway.connection.request("message.action", $0) },
        records: { await gateway.connection.demoRecordedActions() })
}
