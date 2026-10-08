import Foundation
@testable import PincerKit

/// Until-changed dismissals must not outlive an occurrence: a channel that stops again has a new
/// `lastStopAt`, so it returns even if it cleared while no device was connected (#139).
@MainActor
func runHealthRecurrenceChecks() {
    func issue(_ account: JSONValue) -> GatewayHealthIssue? {
        GatewayHealthRules.issues(health: GatewayHealthSummary(["ok": true, "channels": ["discord": account]]),
                                 heartbeat: nil, now: Date(timeIntervalSince1970: 1_700_000_000)).first
    }
    func stopped(_ at: Double) -> JSONValue { ["configured": true, "running": false, "lastStopAt": .number(at)] }
    guard let first = issue(stopped(1_700_000_000_000)), let same = issue(stopped(1_700_000_000_000)),
          let again = issue(stopped(1_700_000_900_000))
    else { return check(false, "stopped channel reports an issue") }
    let dismissal = GatewayHealthDismissal.untilChanged(first.fingerprint)
    check(first.fingerprint.hasPrefix("state=not-running"), "fingerprint keeps the state")
    check(GatewayHealthRules.isDismissed(same, by: dismissal), "same occurrence stays dismissed")
    check(!GatewayHealthRules.isDismissed(again, by: dismissal), "a later stop resurfaces a dismissed issue")
    check(GatewayHealthRules.isDismissed(again, by: .untilChanged("state=not-running")),
          "a legacy dismissal without a marker still hides the issue")
    check(issue(["configured": true, "running": false])?.fingerprint == "state=not-running",
          "no Gateway timestamp leaves the fingerprint unchanged")
}
