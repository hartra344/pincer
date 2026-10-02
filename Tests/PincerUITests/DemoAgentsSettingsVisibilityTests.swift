import Testing
@testable import PincerKit
@testable import PincerUI

/// #519: the demo should expose Agents & Models without replacing its seeded agent-management data.
@Suite(.serialized)
@MainActor
struct DemoAgentsSettingsVisibilityTests {
    @Test func demoShowsAgentsAndModelsWithItsSeededPetIdentity() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        defer { gateway.stop() }

        let ready = await eventually(timeout: .seconds(60)) {
            gateway.state.isConnected && gateway.agents.contains { $0.id == "main" }
        }
        try #require(ready, "demo did not load its seeded main agent")

        await gateway.settings.load()
        let visiblePageIDs = SettingsCatalog.pages.filter { gateway.settings.shows($0) }.map(\.id)
        #expect(visiblePageIDs.contains(SettingsCatalog.agentsPageId), "Agents & Models should be available in the demo")

        let agent = try #require(gateway.agents.first { $0.id == "main" })
        let identity = try await gateway.agentManagement.identity(agentId: agent.id)
        #expect(identity.name == agent.name)
        #expect(identity.emoji == agent.emoji)

        // Exercise the same seeded identity/choice projection used by the Pet picker row.
        let seed = gateway.avatarSeed(for: agent)
        let style = AvatarSettings.style(
            for: agent,
            seed: seed,
            creature: gateway.avatarCreature(for: agent.id)?.rawValue ?? "",
            renderStyle: scratch.defaults.string(forKey: AvatarPreferences.renderStyleKey) ?? "")
        #expect(seed == AvatarStyle.identitySeed(name: identity.name, agentId: agent.id))
        #expect(style == AvatarStyle.seeded(from: seed))

        // Exercise the same local selection and rendered-style path as the Pet picker without
        // leaving an asynchronous Gateway prefs write behind in this fixture.
        // Stop the actor directly so it emits `.idle` through the still-live store event pump.
        // `GatewayStore.stop()` cancels that pump first, leaving its published state connected.
        await gateway.connection.stop()
        let stopped = await eventually(timeout: .seconds(10)) { gateway.state == .idle }
        try #require(stopped, "demo Gateway store did not observe the connection stopping")
        gateway.stop()
        defer { gateway.queuedAvatarChoices = [:] }

        gateway.setAvatarCreature(.cat, for: agent.id)
        let selectedStyle = AvatarSettings.style(
            for: agent,
            seed: gateway.avatarSeed(for: agent),
            creature: gateway.avatarCreature(for: agent.id)?.rawValue ?? "",
            renderStyle: scratch.defaults.string(forKey: AvatarPreferences.renderStyleKey) ?? "")
        #expect(selectedStyle.creature == .cat)

        gateway.setAvatarCreature(nil, for: agent.id)
        let restoredStyle = AvatarSettings.style(
            for: agent,
            seed: gateway.avatarSeed(for: agent),
            creature: gateway.avatarCreature(for: agent.id)?.rawValue ?? "",
            renderStyle: scratch.defaults.string(forKey: AvatarPreferences.renderStyleKey) ?? "")
        #expect(restoredStyle == style, "Auto restores the seeded Pet after a local choice is cleared")
    }
}
