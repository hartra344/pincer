import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
@testable import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runContextUsageChecks() {
    do {
        let fresh = SessionRow(json(#"{"key":"k","totalTokens":172000,"totalTokensFresh":true,"inputTokens":1200,"outputTokens":340,"contextTokens":200000}"#))!
        let usage = ContextUsage(row: fresh)
        check(usage == ContextUsage(used: 172_000, limit: 200_000) && usage?.level == .warning && usage?.percent == 86,
              "usage from row (\(String(describing: usage)))")
        check(usage?.summary == "172k / 200k" && usage?.percentLabel == "86%" && usage?.remaining == 28_000, "usage labels")
        check(fresh.inputTokens == 1200 && fresh.outputTokens == 340, "last run in/out tokens")
        let stale = SessionRow(json(#"{"key":"k","totalTokens":198000,"totalTokensFresh":false,"contextTokens":200000}"#))!
        check(ContextUsage(row: stale)?.level == .normal && ContextUsage(row: stale)?.summary == "~198k / 200k",
              "stale totals are approximate and never warn")
        let budget = SessionRow(json(#"{"key":"k","totalTokens":150000,"contextTokens":200000,"contextBudgetStatus":{"promptBudgetBeforeReserve":160000}}"#))!
        let budgetUsage = ContextUsage(row: budget)
        check(budgetUsage?.limit == 160_000 && budgetUsage?.isPromptBudget == true && budgetUsage?.level == .warning,
              "prompt budget preferred over the window")
        let noLimit = SessionRow(json(#"{"key":"k","totalTokens":12000,"contextTokens":0}"#))!
        check(ContextUsage(row: noLimit) == nil && ContextUsage(row: noLimit, fallbackLimit: 128_000)?.limit == 128_000,
              "fallback limit when the row has none")
        check(ContextUsage(row: SessionRow(json(#"{"key":"k","contextTokens":200000}"#))!) == nil && ContextUsage(row: nil) == nil,
              "no snapshot, no meter")
        check(ContextUsage(used: 169_999, limit: 200_000).level == .normal && ContextUsage(used: 170_000, limit: 200_000).level == .warning
              && ContextUsage(used: 190_000, limit: 200_000).level == .critical, "warning at 85%, critical at 95%")
        check(ContextUsage(used: 260_000, limit: 200_000).percent == 100 && ContextUsage(used: 260_000, limit: 200_000).remaining == 0,
              "overflow clamps")
        let huge = SessionRow(json(#"{"key":"huge","totalTokens":1000000000000000000,"contextTokens":1}"#))!
        let hugeUsage = ContextUsage(row: huge)
        check(huge.totalTokens == 1_000_000_000_000_000_000 && hugeUsage?.percent == 100
              && hugeUsage?.percentLabel == "100%", "accepted huge session token count safely caps before conversion")
        check(ContextUsage(used: Int.max, limit: 1).percent == 100
              && ContextUsage(used: Int.max, limit: Int.max).percent == 100
              && ContextUsage(used: 1, limit: Int.max).percent == 0,
              "representable integer extremes remain bounded")
        check(ContextUsage(used: Int.min, limit: 1).percent == 0
              && ContextUsage(used: Int.max, limit: 0).percent == 0
              && ContextUsage(used: Int.max, limit: Int.min).percent == 0,
              "invalid direct-constructor inputs produce zero percent")
        check(ContextUsage(used: 1, limit: 200).percent == 1
              && ContextUsage(used: 199, limit: 200).percent == 100, "ordinary percentage rounding is preserved")
        check([950, 12_300, 40_000, 99_960, 172_400, 999_700, 1_260_000].map(TokenCount.format)
              == ["950", "12.3k", "40k", "100k", "172k", "1M", "1.3M"], "token formatting")
        check(ModelChoice(json(#"{"id":"a","provider":"p","contextWindow":1000000,"contextTokens":200000}"#))?.contextTokens == 200_000
              && ModelChoice(json(#"{"id":"a","provider":"p","contextWindow":1000000}"#))?.contextTokens == 1_000_000
              && ModelChoice(json(#"{"id":"a","provider":"p"}"#))?.contextTokens == nil, "model context cap prefers contextTokens")
        check(CompactionState.finished(before: 172_000, after: 31_000).message == "Compacted 172k → 31k tokens."
              && CompactionState.finished(before: nil, after: 31_000).message == "Compacted to 31k tokens."
              && CompactionState.running(before: 1).isRunning && !CompactionState.skipped("x").isRunning, "compaction messages")
    }
}

@MainActor
func checkDemoContextPercentage(_ gateway: GatewayStore) {
    let usage = gateway.contextUsage(for: "agent:main:dashboard:trip")
    check(usage?.used == 192_000 && usage?.limit == 200_000 && usage?.level == .critical,
          "actual seeded Demo session retains its context source and warning level")
    check(usage?.percent == 96 && usage?.percentLabel == "96%"
          && usage.map { AccessibilityText.contextMeterValue($0).hasPrefix("96 percent used") } == true,
          "connected Demo session context produces the exact percentage and spoken value")
}

@MainActor
func runDemoContextUsageChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("context Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped
            && gateway.sessions["agent:main:dashboard:trip"] != nil
    }) else {
        check(false, "context checks connect to actual seeded Demo sessions")
        return
    }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    check(chat.hasLoaded && !chat.items.isEmpty, "actual Demo context chat loads its transcript")
    checkDemoContextPercentage(gateway)
}
