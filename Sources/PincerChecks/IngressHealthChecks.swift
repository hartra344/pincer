import Foundation
@testable import PincerKit

/// Actual public summary/rules, using verified upstream ingress health records.
@MainActor
func runIngressHealthChecks() {
    func issues(_ queues: JSONValue) -> [GatewayHealthIssue] {
        GatewayHealthRules.issues(health: GatewayHealthSummary(["ok": true, "deliveryQueues": queues]),
                                 heartbeat: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
    }
    for pressure in [false, true] {
        let key = pressure ? "ingressPressure" : "ingressFailed"
        func record(_ count: Int) -> JSONValue {
            if pressure {
                return ["channelId": "telegram", "accountId": "work", "laneCount": 1,
                        "pendingCount": .number(Double(count)), "claimedCount": 0, "blockedCount": 1,
                        "oldestReceivedAt": 1_700_000_000_000]
            }
            return ["channelId": "telegram", "accountId": "work", "count": .number(Double(count)),
                    "oldestFailedAt": 1_700_000_000_000]
        }
        let current = issues(.object([key: .array([record(3)])]))
        check(current.count == 1 && current.first?.kind == .delivery, "reported \(key) creates a delivery issue")
        guard let issue = current.first else { continue }
        let dismissal = GatewayHealthDismissal.untilChanged(issue.fingerprint)
        let lower = issues(.object([key: .array([record(2)])])).first
        let grown = issues(.object([key: .array([record(4)])])).first
        check(issue.detail?.contains("telegram") == true && issue.detail?.contains("work") == true
              && !issue.canAlwaysIgnore, "ingress issue identifies the account and cannot be ignored forever")
        check(lower.map { $0.id == issue.id && GatewayHealthRules.isDismissed($0, by: dismissal) } == true
              && grown.map { $0.id == issue.id && !GatewayHealthRules.isDismissed($0, by: dismissal) } == true,
              "ingress dismissal stays hidden at lower counts and returns on growth")
    }
    check(issues(["failed": [["queueName": "outbound", "count": 2]]]).first?.fingerprint == "count=2",
          "existing outbound failure remains intact")
    check(issues(["ingressFailed": [], "ingressPressure": []]).isEmpty
          && issues(["ingressFailed": [["count": 0]], "ingressPressure": "wrong"]).isEmpty,
          "empty, zero and malformed ingress records do not invent issues")
}

@MainActor
private func runConnectedIngressHealthChecks(profile: GatewayProfile, label: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("\(label) ingress connection", timeout: 25) { gateway.state.isConnected }
    check(connected, "\(label) connects for actual ingress health")
    guard connected else { return }
    do {
        let response = try await gateway.connection.request("health", [:], timeout: 20)
        check(response["deliveryQueues"]?["ingressFailed"]?.array?.first?["count"] == 2
              && response["deliveryQueues"]?["ingressPressure"]?.array?.first?["pendingCount"] == 3,
              "\(label) actual health RPC includes both seeded upstream signals")
        let model = GatewayHealthModel { method, params in
            try await gateway.connection.request(method, params, timeout: 20)
        }
        await model.load()
        let ingress = model.activeIssues.filter { $0.id.hasPrefix("queue:ingress-") }
        check(ingress.count == 2 && ingress.allSatisfy { $0.kind == .delivery && !$0.canAlwaysIgnore },
              "\(label) actual loaded model displays both ingress delivery issues")
        for issue in ingress { model.dismiss(issue) }
        check(!model.activeIssues.contains { $0.id.hasPrefix("queue:ingress-") }
              && model.dismissedIssues.filter { $0.id.hasPrefix("queue:ingress-") }.count == 2,
              "\(label) actual model dismisses each ingress account signal")
    } catch { check(false, "\(label) ingress health RPC failed: \(error)") }
}

@MainActor
func runDemoIngressHealthChecks() async {
    await runConnectedIngressHealthChecks(profile: .demo(), label: "Demo")
}

@MainActor
func runLiveIngressHealthChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Ingress health mock", url: url, authMode: .token)
    profile.secret = token
    await runConnectedIngressHealthChecks(profile: profile, label: "Mock")
}
