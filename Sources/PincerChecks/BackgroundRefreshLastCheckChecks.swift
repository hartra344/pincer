import Foundation
@testable import PincerKit

@MainActor func runBackgroundRefreshLastCheckChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    check(BackgroundRefreshLastCheck(defaults: defaults).date == nil, "missing saved refresh date stays Not yet")
    let date = Date(timeIntervalSince1970: 1234)
    defaults.set(date, forKey: "pincer.refresh.lastRun")
    defaults.set("Up to date", forKey: "pincer.refresh.lastResult")
    let saved = BackgroundRefreshLastCheck(defaults: defaults)
    check(saved.date == date && saved.result == "Up to date", "actual settings read retains exact saved date and result")
}
@MainActor func runDemoBackgroundRefreshLastCheckChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("last check Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo connection ready"); guard ready else { return }
    defaults.set(true, forKey: "pincer.notifications")
    ClosedAppDelivery.set(.backgroundRefresh, defaults)
    // Demo profiles are deliberately skipped by background refresh. This checks the actual
    // completed runner's saved status, not a claim that it polled the Demo in background.
    let runner = BackgroundRefresh(profiles: { [gateway.profile] }, defaults: defaults, post: { _ in }, setBadge: { _ in })
    let report = await runner.run()
    let saved = BackgroundRefreshLastCheck(defaults: defaults)
    check(!report.skipped && saved.date != nil && saved.result == "Up to date", "actual completed refresh saves the exact settings status")
}
