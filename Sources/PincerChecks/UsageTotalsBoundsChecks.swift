import Foundation
@testable import PincerKit

@MainActor
func runUsageTotalsBoundsChecks() async {
    let bounded = UsageTotals(json(#"{"input":1e30,"output":-1,"totalTokens":42,"missingCostByModel":{"provider/model":1e30}}"#))
    check(bounded.input == Int.max && bounded.output == 0 && bounded.totalTokens == 42
          && bounded.missingCostByModel["provider/model"] == Int.max, "count decoding bounds extremes while explicit totals win")
    let large = UsageTotals(json(#"{"input":4000000000000000000,"output":4000000000000000000,"cacheRead":4000000000000000000,"cacheWrite":4000000000000000000}"#))
    check(large.totalTokens == Int.max && (large + large).cacheTokens == Int.max,
          "fallback, aggregation and cache sums saturate instead of trapping")
    let invalid = UsageTotals(.object(["input": .number(.infinity), "output": .number(.nan)]))
    check(invalid.input == 0 && invalid.output == 0, "nonfinite counts default to zero")
    var calls = 0
    let model = UsageModel(methods: { ["sessions.usage"] }, request: { method, _ in
        calls += 1
        guard method == "sessions.usage" else { throw GatewayError.closed("Unexpected usage method") }
        return json(#"{"sessions":[],"totals":{"input":1e30,"totalTokens":42,"totalCost":1.25}}"#)
    })
    await model.loadSessions()
    check(calls == 1 && model.sessions.value?.totals.input == Int.max
          && model.totals?.totalTokens == 42 && model.totals?.totalCost == 1.25,
          "actual UsageModel publishes an oversized report without changing monetary fields")
}

@MainActor
func runDemoUsageTotalsBoundsChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("usage totals Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped
    }) else { check(false, "usage bounds connect to genuine Demo"); return }
    await gateway.usage.loadSessions()
    guard let result = gateway.usage.sessions.value else {
        check(false, "actual Demo sessions.usage returns decoded totals"); return
    }
    check(result.totals.totalTokens > 0 && result.totals.totalCost > 0,
          "genuine Demo usage keeps seeded counts and costs")
    var huge = UsageTotals()
    huge.input = Int.max
    huge.totalTokens = Int.max
    huge.cacheRead = Int.max
    let combined = result.totals + huge
    check(combined.input == Int.max && combined.totalTokens == Int.max
          && combined.cacheTokens == Int.max && combined.totalCost == result.totals.totalCost,
          "aggregating genuine Demo usage with bounded extremes preserves cost and caps counts")
}
