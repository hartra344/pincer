import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

#if DEBUG
@MainActor
func runAvatarSeedReadAuthorization() {
    check(GatewayStore.AvatarPrefsPullAuthorization.promotedEpoch(readEpoch: 3, readSucceeded: false, currentEpoch: 3) == nil,
          "a failed preference read cannot authorize a new avatar seed")
    check(GatewayStore.AvatarPrefsPullAuthorization.promotedEpoch(readEpoch: 3, readSucceeded: true, currentEpoch: 3) == 3,
          "a successful empty-profile read authorizes seeds for this connection")
    check(GatewayStore.AvatarPrefsPullAuthorization.promotedEpoch(readEpoch: 2, readSucceeded: true, currentEpoch: 3) == nil,
          "a stale connection's successful read cannot authorize seeds")
}

/// The demo's first `users.prefs.get` for avatar settings fails transiently. A previously synced
/// device must wait for the retry and preserve the Gateway's older seed for Scout (#520).
@MainActor
func runDemoAvatarSeedRecovery() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let profile = GatewayProfile.demoAvatarPrefsReadFailure()
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    for map in gateway.syncedMaps { defaults.set(true, forKey: map.syncedDefaultsKey) }
    defer { gateway.stop() }
    gateway.start()

    let entry = AvatarPreferences.seedEntry(for: "research")
    let remoteSeed = "Earlier Scout identity"
    let recovered = await waitFor("demo avatar prefs read recovers", timeout: 15) {
        gateway.state.isConnected && gateway.avatarChoices[entry] == remoteSeed
    }
    check(recovered, "demo retry applies the older Gateway seed after a failed prefs read (\(gateway.avatarChoices[entry] ?? "nil"))")
    check(gateway.avatarSeed(for: AgentSummary(id: "research", name: "Scout")) == remoteSeed,
          "demo Scout keeps the identity seed established by the Gateway")

    guard recovered else { return }
    let stored = try? await gateway.connection.request("users.prefs.get", ["keys": [.string(AvatarPreferences.prefKey)]])
    check(stored?["entries"]?[AvatarPreferences.prefKey]?[entry]?.text == remoteSeed,
          "demo Gateway still stores its older seed after recovery")
}
#else
@MainActor
func runAvatarSeedReadAuthorization() {}
@MainActor
func runDemoAvatarSeedRecovery() async {}
#endif
