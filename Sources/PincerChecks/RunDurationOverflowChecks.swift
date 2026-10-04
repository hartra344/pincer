import Foundation
@testable import PincerKit

@MainActor func runRunDurationOverflowChecks() {
    var timeline = RunTimeline()
    let received = Date(timeIntervalSince1970: 1)
    // LOCAL legal AgentEvent boundary only; no Gateway response or event is modified.
    let start: JSONValue = ["runId": "local-duration", "seq": 1, "stream": "lifecycle", "ts": 1000,
                            "data": ["phase": "start", "startedAt": 1000]]
    let end: JSONValue = ["runId": "local-duration", "seq": 2, "stream": "lifecycle", "ts": .number(1e30),
                          "data": ["phase": "end", "endedAt": .number(1e30)]]
    check(timeline.apply(agent: start, receivedAt: received) && timeline.apply(agent: end, receivedAt: received),
          "actual Runs timeline accepts both local legal lifecycle events")
    guard let lane = timeline.lane("local-duration"), lane.status == .done, lane.endedAt != nil else {
        check(false, "local boundary has an actual completed lane"); return
    }
    let duration = lane.duration(now: received)
    check(duration.isFinite && duration > Double(Int.max), "actual lane duration reaches integer boundary")
    check(!RunDuration.format(duration).isEmpty, "actual Runs formatter handles the local finite boundary")
}

@MainActor func runDemoRunDurationOverflowChecks() async {
    let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    guard await waitFor("actual Demo Runs duration", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped
        && gateway.runTimeline.latestLane(sessionKey: "agent:research:dashboard:launch-plan")?.status == .done
    }) else { check(false, "actual Demo supplies completed launch-plan activity"); return }
    guard let lane = gateway.runTimeline.latestLane(sessionKey: "agent:research:dashboard:launch-plan") else {
        check(false, "actual Demo lane is retained"); return
    }
    let duration = lane.duration(now: Date())
    check(duration.isFinite && duration >= 1 && duration < Double(Int.max), "genuine Demo lane has an ordinary completed duration")
    check(!RunDuration.format(duration).isEmpty, "actual Runs formatter renders genuine Demo activity")
    runRunDurationOverflowChecks()
}
