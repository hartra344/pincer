import Foundation
import PincerKit

@MainActor
private final class ChannelPollingClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor
func runChannelPollingChecks() async {
    let clock = ChannelPollingClock()
    var requests = 0
    let model = ChannelsModel(now: { clock.date }) { _, _ in
        requests += 1
        return ["channelOrder": [], "channelAccounts": [:]]
    }
    await model.load()
    await model.poll()
    check(requests == 1, "fresh channel status skips the periodic RPC")
    clock.date += 30
    await model.poll()
    await model.poll()
    check(requests == 2, "stale channel status refreshes once and resets freshness")
    await model.refresh()
    await model.probe()
    check(requests == 4, "manual refresh and probe bypass freshness")
    model.reset()
    await model.poll()
    check(requests == 5, "reset clears channel status freshness")
}

/// Exercise the same fallback with realistic status data and the built-in Gateway transport.
@MainActor
func runDemoChannelPollingChecks() async {
    let connection = GatewayConnection(profile: .demo())
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    let connected = await waitFor("channel polling demo connection") { ready.value }
    guard connected else {
        return check(false, "channel polling demo connects")
    }
    let clock = ChannelPollingClock()
    var requests = 0
    let model = ChannelsModel(now: { clock.date }) { method, params in
        requests += 1
        return try await connection.request(method, params)
    }
    await model.load()
    await model.poll()
    check(model.snapshot?.channel("discord") != nil && requests == 1,
          "demo fresh channel status keeps the seeded snapshot without an extra RPC")
    model.isShowing = true
    clock.date += 6
    model.healthDidChange()
    let refreshed = await waitFor("channel polling health refresh") {
        requests == 2 && model.loadState == .idle
    }
    check(refreshed, "demo health update refreshes channel status")
    clock.date += 29
    await model.poll()
    check(requests == 2, "demo fallback skips a recent health refresh")
    clock.date += 1
    await model.poll()
    check(requests == 3, "demo fallback refreshes once health updates go stale")
}
