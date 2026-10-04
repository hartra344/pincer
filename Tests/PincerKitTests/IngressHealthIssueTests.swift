import Foundation
import Testing
@testable import PincerKit

// Upstream 9c66d4c9a39b16d70e7c55186fe7e8550468a663:
// src/channels/message/ingress-queue-read-contract.ts and gateway/health/delivery-queue.ts.
@Suite("Ingress health issues")
struct IngressHealthIssueTests {
    static func issues(_ queues: JSONValue) throws -> [GatewayHealthIssue] {
        let health = try #require(GatewayHealthSummary(["ok": true, "deliveryQueues": queues]))
        return GatewayHealthRules.issues(health: health, heartbeat: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func entry(pressure: Bool, count: Int) -> JSONValue {
        if pressure {
            return ["channelId": "telegram", "accountId": "work", "laneCount": 1,
                    "pendingCount": .number(Double(count)), "claimedCount": 0, "blockedCount": 1,
                    "oldestReceivedAt": 1_700_000_000_000]
        }
        return ["channelId": "telegram", "accountId": "work", "count": .number(Double(count)),
                "oldestFailedAt": 1_700_000_000_000]
    }

    @Test(arguments: [false, true]) func reportedIngressMakesDeliveryIssue(pressure: Bool) throws {
        let key = pressure ? "ingressPressure" : "ingressFailed"
        let issues = try Self.issues(.object([key: .array([Self.entry(pressure: pressure, count: 3)])]))
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.kind == .delivery && !issue.canAlwaysIgnore)
        #expect(!issue.title.isEmpty && issue.detail?.contains("telegram") == true && issue.detail?.contains("work") == true)
        #expect(GatewayHealthRules.level(connection: .connected, restarting: false, healthUnavailable: false,
                                        issueCount: issues.count) == .degraded)
        let dismissal = GatewayHealthDismissal.untilChanged(issue.fingerprint)
        let lower = try #require(try Self.issues(.object([key: .array([Self.entry(pressure: pressure, count: 2)])])).first)
        let grown = try #require(try Self.issues(.object([key: .array([Self.entry(pressure: pressure, count: 4)])])).first)
        #expect(issue.id == lower.id && issue.id == grown.id)
        #expect(GatewayHealthRules.isDismissed(issue, by: dismissal))
        #expect(GatewayHealthRules.isDismissed(lower, by: dismissal))
        #expect(!GatewayHealthRules.isDismissed(grown, by: dismissal))
    }

    @Test func ordinaryFailedQueueAndHealthyControls() throws {
        let ordinary = try Self.issues(["failed": [["queueName": "outbound", "count": 2]]])
        #expect(ordinary.map(\.id) == ["queue:outbound"] && ordinary.first?.fingerprint == "count=2")
        for queues in [JSONValue.object([:]), ["ingressFailed": [], "ingressPressure": []],
                       ["ingressFailed": [["channelId": "telegram", "accountId": "work", "count": 0]],
                        "ingressPressure": [["channelId": "telegram", "accountId": "work", "laneCount": 0,
                                             "pendingCount": 0, "claimedCount": 0, "blockedCount": 0,
                                             "oldestReceivedAt": 1_700_000_000_000]]],
                       ["ingressFailed": [Self.nullEntry], "ingressPressure": "wrong"]] {
            #expect(try Self.issues(queues).isEmpty)
        }
    }

    static let nullEntry: JSONValue = ["channelId": false, "accountId": 9, "count": "three"]
    @Test func countBoundsAndIndependentPressureGrowth() throws {
        let huge = try Self.issues(["ingressFailed": [["channelId": "telegram", "accountId": "work", "count": 1e30]]])
        #expect(huge.first?.fingerprint == "count=\(Int.max)")
        func pressure(_ pending: Double, _ claimed: Double, _ blocked: Double) throws -> GatewayHealthIssue {
            try #require(try Self.issues(["ingressPressure": [["channelId": "telegram", "accountId": "work",
                "pendingCount": .number(pending), "claimedCount": .number(claimed), "blockedCount": .number(blocked),
                "laneCount": 1, "oldestReceivedAt": 1_700_000_000_000]]]).first)
        }
        let before = try pressure(2, 2, 2)
        for after in [try pressure(3, 1, 1), try pressure(1, 3, 1), try pressure(1, 1, 3)] {
            #expect(!GatewayHealthRules.isDismissed(after, by: .untilChanged(before.fingerprint)))
        }
        let bounded = try pressure(1e30, .infinity, -1)
        #expect(bounded.fingerprint == "pending=\(Int.max);claimed=0;blocked=0")
        #expect(GatewayHealthRules.isDismissed(try pressure(1, 1, 1), by: .untilChanged(before.fingerprint)))
    }

}
