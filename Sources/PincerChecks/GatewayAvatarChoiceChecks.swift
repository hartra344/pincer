import Foundation
#if DEBUG
@testable import PincerKit

@MainActor
func runGatewayAvatarChoiceChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let homeProfile = GatewayProfile(name: "Home avatars", url: "ws://127.0.0.1:1", authMode: .none)
    let home = GatewayStore(profile: homeProfile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let work = GatewayStore(profile: GatewayProfile(name: "Work avatars", url: "ws://127.0.0.1:1", authMode: .none),
                            defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    home.setAvatarCreature(.cat, for: "main")
    work.setAvatarCreature(.owl, for: "main")
    check(home.avatarCreature(for: "main") == .cat && work.avatarCreature(for: "main") == .owl,
          "avatar scope: same agent ID keeps each Gateway's character")
    let reopened = GatewayStore(profile: homeProfile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    check(reopened.avatarCreature(for: "main") == .cat,
          "avatar scope: reopening restores the owning Gateway's choice")
    home.setAvatarCreature(nil, for: "main")
    check(home.avatarCreature(for: "main") == nil && work.avatarCreature(for: "main") == .owl,
          "avatar scope: Auto on one Gateway preserves the other Gateway's choice")
}

@MainActor
func runDemoGatewayAvatarChoices() async {
    let (defaults, suite) = scratchDefaults()
    // Existing installs can have a legacy global choice. Auto must stay cleared after sync.
    defaults.set("cat", forKey: AvatarPreferences.creatureKey(for: "main"))
    let home = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let work = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    home.cacheRoot = nil
    work.cacheRoot = nil
    home.start()
    work.start()
    defer {
        home.stop()
        work.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("two demo avatar Gateways") {
        home.state.isConnected && work.state.isConnected && !home.agents.isEmpty && !work.agents.isEmpty
    }
    check(ready, "avatar scope demo: both Gateways connected with agents")
    guard ready else { return }
    home.setAvatarCreature(.cat, for: "main")
    work.setAvatarCreature(.owl, for: "main")
    let synced = await waitFor("two demo avatar choices synced") {
        home.queuedAvatarChoices.isEmpty && work.queuedAvatarChoices.isEmpty
    }
    check(synced && home.avatarCreature(for: "main") == .cat && work.avatarCreature(for: "main") == .owl,
          "avatar scope demo: synced characters remain distinct for the same agent ID")
    home.setAvatarCreature(nil, for: "main")
    let cleared = await waitFor("demo avatar Auto synced") { home.queuedAvatarChoices.isEmpty }
    check(cleared && home.avatarCreature(for: "main") == nil && work.avatarCreature(for: "main") == .owl,
          "avatar scope demo: clearing one character preserves the other Gateway")
}
#else
func runGatewayAvatarChoiceChecks() {}
func runDemoGatewayAvatarChoices() async {}
#endif
