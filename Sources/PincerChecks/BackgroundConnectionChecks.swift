import Foundation
@testable import PincerKit

// #1074: going to the background keeps the Gateway connections open on iOS's background time, and a
// connection that only looks dead after a suspension is pinged and reused instead of rebuilt.

@MainActor
func runBackgroundConnectionOfflineChecks() {
    var begun = 0, ended = 0, expiries = 0
    var expire: (@MainActor () -> Void)?
    let grace = BackgroundConnectionGrace { name, expired in
        check(name == BackgroundConnectionGrace.activityName, "background time is named")
        begun += 1
        expire = expired
        return { ended += 1 }
    }
    grace.onExpire = { expiries += 1 }
    grace.enterBackground()
    grace.enterBackground()
    check(begun == 1 && grace.isHeld, "backgrounding asks for background time once")
    grace.enterForeground()
    check(ended == 1 && !grace.isHeld, "returning ends it")
    grace.enterBackground()
    expire?()
    check(expiries == 1 && grace.expired && !grace.isHeld, "running out of time reports expiry")
    check(ended == 2, "running out of time ends the background task")
    grace.enterForeground()
    check(!grace.expired && ended == 2, "returning after expiry clears it without ending twice")
    expire?()
    check(expiries == 1, "a late expiry after returning is ignored")
}

@MainActor
func runDemoBackgroundConnectionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = AppModel(defaults: defaults)
    var expire: (@MainActor () -> Void)?
    app.connectionGrace.begin = { _, expired in
        expire = expired
        return {}
    }
    let gateway = app.add(.demoInstantPacing(), secret: nil)
    gateway.deviceNode.handler = CheckNodeHandler()
    gateway.deviceNode.followsAppLifecycle = true
    defer { gateway.stop() }
    guard await waitFor("background demo connects", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "demo connects for background checks"); return
    }
    await gateway.deviceNode.update(DeviceModeSettings(enabled: true))
    let active = await waitFor("background node active", { gateway.deviceNode.status == .active })
    check(active, "device mode node is active")
    let epoch = gateway.connectionEpoch

    app.appIsActive = false
    app.appIsInBackground = true
    try? await Task.sleep(for: .milliseconds(200))
    check(app.connectionGrace.isHeld, "backgrounding holds background time")
    check(gateway.state.isConnected && gateway.deviceNode.status == .active, "both connections stay open in the background")
    let ok = await gateway.demoInvokeNode(command: "location.get")
    check(ok?["ok"]?.bool == true, "the node still answers on background time")

    app.appIsInBackground = false
    app.appIsActive = true
    try? await Task.sleep(for: .milliseconds(200))
    check(gateway.connectionEpoch == epoch && gateway.deviceNode.status == .active, "a quick return reuses the connections")

    app.appIsActive = false
    app.appIsInBackground = true
    expire?()
    check(gateway.deviceNode.status == .paused && gateway.state.isConnected, "out of background time → node paused, operator left open")
    app.appIsInBackground = false
    app.appIsActive = true
    let resumed = await waitFor("node resumes", { gateway.deviceNode.status == .active })
    check(resumed, "returning resumes the node")
}

/// The failing repro: after a suspension the socket missed its ticks but is fine; returning used
/// to tear it down and reconnect (a "Connecting…" flash and a full bootstrap).
@MainActor
func runLiveBackgroundConnectionChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Background check", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start()
    defer { gateway.stop(); profile.forgetCredentials() }
    guard await waitFor("background live connects", timeout: 25, { gateway.state.isConnected && gateway.hello != nil }) else {
        check(false, "live connects for background checks"); return
    }
    let epoch = gateway.connectionEpoch

    await gateway.connection.simulateMissedHeartbeats()
    await gateway.connection.reconnectNow()
    let ready = await gateway.connection.isReady
    check(ready && gateway.connectionEpoch == epoch,
          "returning with a quiet but live socket reuses it (epoch \(epoch) → \(gateway.connectionEpoch))")

    await gateway.connection.simulateMissedHeartbeats()
    try? await Task.sleep(for: .seconds(6))
    check(gateway.state.isConnected && gateway.connectionEpoch == epoch, "the watchdog pings a quiet socket before dropping it")
    let reply = try? await gateway.connection.request("health", [:])
    check(reply != nil, "the reused socket still answers requests")
}
