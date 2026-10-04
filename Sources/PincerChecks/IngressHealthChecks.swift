import Foundation
import PincerKit

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
