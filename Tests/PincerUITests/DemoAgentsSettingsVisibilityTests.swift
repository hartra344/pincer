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
    }
}
