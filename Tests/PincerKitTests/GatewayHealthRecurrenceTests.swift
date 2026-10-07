import Foundation
import Testing
@testable import PincerKit

// Upstream openclaw packages/gateway-protocol/src/schema/channels.ts (ChannelAccountSnapshot):
// lastStartAt, lastStopAt, lastConnectedAt; src/gateway/server-channels.ts sets lastStopAt on every stop.
@Suite("Health dismissal recurrence")
struct GatewayHealthRecurrenceTests {
    static func channelIssue(_ account: JSONValue) throws -> GatewayHealthIssue {
        let health = try #require(GatewayHealthSummary(["ok": true, "channels": ["discord": account]]))
        let issues = GatewayHealthRules.issues(health: health, heartbeat: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
        return try #require(issues.first)
    }

    static func stopped(at: Double?) -> JSONValue {
        var account: [String: JSONValue] = ["configured": true, "running": false]
        if let at { account["lastStopAt"] = .number(at) }
        return .object(account)
    }

    @Test func notRunningThatReturnsAfterClearingComesBack() throws {
        let first = try Self.channelIssue(Self.stopped(at: 1_700_000_000_000))
        let dismissal = GatewayHealthDismissal.untilChanged(first.fingerprint)
        let sameOccurrence = try Self.channelIssue(Self.stopped(at: 1_700_000_000_000))
        let recurrence = try Self.channelIssue(Self.stopped(at: 1_700_000_900_000))
        #expect(GatewayHealthRules.isDismissed(sameOccurrence, by: dismissal))
        #expect(!GatewayHealthRules.isDismissed(recurrence, by: dismissal))
    }

    @Test func notConnectedRecurrenceUsesLastConnectedAt() throws {
        func account(_ at: Double) -> JSONValue { ["configured": true, "running": true, "connected": false, "lastConnectedAt": .number(at)] }
        let dismissal = GatewayHealthDismissal.untilChanged(try Self.channelIssue(account(1_700_000_000_000)).fingerprint)
        #expect(GatewayHealthRules.isDismissed(try Self.channelIssue(account(1_700_000_000_000)), by: dismissal))
        #expect(!GatewayHealthRules.isDismissed(try Self.channelIssue(account(1_700_000_900_000)), by: dismissal))
    }

    @Test func legacyFingerprintStillHidesSameKind() throws {
        let issue = try Self.channelIssue(Self.stopped(at: 1_700_000_900_000))
        #expect(GatewayHealthRules.isDismissed(issue, by: .untilChanged("state=not-running")))
        #expect(!GatewayHealthRules.isDismissed(issue, by: .untilChanged("state=not-connected")))
    }

    @Test func withoutMarkerFingerprintIsUnchanged() throws {
        #expect(try Self.channelIssue(Self.stopped(at: nil)).fingerprint == "state=not-running")
    }
}
