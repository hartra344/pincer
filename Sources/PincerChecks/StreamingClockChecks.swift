import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runStreamingClockChecks() {
    #if DEBUG
    let frame = 1.0 / 60.0
    let delayAfterBackwardAdjustment = ChatStore.coalescedFlushDelay(interval: frame, elapsed: -3_600)
    check(abs(delayAfterBackwardAdjustment - frame) < 0.000_001,
          "stream clock: backward wall-clock adjustment is bounded to one frame")
    check(abs(ChatStore.coalescedFlushDelay(interval: frame, elapsed: 0) - frame) < 0.000_001,
          "stream clock: a same-instant burst waits one frame")
    check(abs(ChatStore.coalescedFlushDelay(interval: frame, elapsed: frame / 2) - frame / 2) < 0.000_001,
          "stream clock: normal elapsed time preserves the remaining coalescing window")
    check(ChatStore.coalescedFlushDelay(interval: frame, elapsed: frame) == 0,
          "stream clock: an elapsed frame is due immediately")
    #endif
}

@MainActor
func runDemoStreamingClockChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.start()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ready = await waitFor("demo streaming clock") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "stream clock demo: connected")
    guard ready else { await gateway.stopAndFlushCache(); return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    func visibleBody() -> String? {
        chat.entries.reversed().compactMap { entry -> String? in
            if case let .assistant(turn) = entry, turn.isStreaming { return turn.body }
            return nil
        }.first
    }
    await chat.send("long")
    let started = await waitFor("demo streaming clock first text") { visibleBody()?.isEmpty == false }
    check(started, "stream clock demo: actual reply begins publishing text")
    guard started else { await gateway.stopAndFlushCache(); return }
    chat.flushLive()
    let before = visibleBody() ?? ""
    chat.lastPublishAt = Date().addingTimeInterval(3_600)
    let grows = await waitFor("demo streaming clock growth", timeout: 2) {
        guard let body = visibleBody() else { return false }
        return body.count > before.count && body.hasPrefix(before)
    }
    check(grows, "stream clock demo: text keeps growing after a simulated clock rollback, before terminal flush")
    let finished = await waitFor("demo streaming clock terminal", timeout: 20) { !chat.isRunning }
    check(finished, "stream clock demo: the actual terminal event still completes the reply")
    await gateway.stopAndFlushCache()
    #endif
}
