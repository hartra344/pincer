import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runLocationSelectionChecks() async {
    #if DEBUG
    let suite = "PincerChecks.locationSelection.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let profile = GatewayProfile(name: "Offline location selection", url: "ws://127.0.0.1:1", authMode: .none)
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    let mainKey = "agent:main:main"
    let observedKey = "agent:main:location-observer"
    let main = gateway.chat(for: mainKey)
    let observed = gateway.chat(for: observedKey)
    for chat in [main, observed] {
        chat.draftChecked = true
        chat.cacheChecked = true
    }

    observed.hasLoaded = true
    observed.stale = false
    observed.subscribedEpoch = gateway.connectionEpoch
    gateway.selectedKey = mainKey
    let retired = await waitFor("unselected location observer releases", timeout: 2) {
        observed.stale && !observed.isSubscribed
    }
    check(retired && !gateway.warmKeys(includingLive: true).contains(observedKey),
          "late Main selection retires an unselected location chat without cache or network access")

    observed.stale = false
    observed.subscribedEpoch = gateway.connectionEpoch
    gateway.selectedKey = observedKey
    gateway.selectedKey = mainKey
    // Retirement happens in an asynchronous task, so observe retention after it can run.
    try? await Task.sleep(for: .milliseconds(50))
    check(gateway.warmKeys(includingLive: true).contains(observedKey)
          && observed.isSubscribed && !observed.stale,
          "a recently selected location chat remains warm when Main is selected afterward")
    gateway.stop()
    #else
    print("  · location selection retention requires debug checks; skipped")
    #endif
}
