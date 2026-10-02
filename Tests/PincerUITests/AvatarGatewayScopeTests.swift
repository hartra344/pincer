import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #518: two Gateways may use the same agent id while keeping different synced avatar choices.
@MainActor
@Suite("Avatar choices per Gateway")
struct AvatarGatewayScopeTests {
    private func gateway(_ name: String, defaults: UserDefaults) -> GatewayStore {
        GatewayStore(
            profile: GatewayProfile(name: name, url: "ws://127.0.0.1:1", authMode: .none),
            defaults: defaults,
            identity: UIFixtures.identity())
    }

    private func loadMainAgent(_ gateway: GatewayStore, name: String) {
        gateway.applyAgents([
            "agents": .array([.object(["id": .string("main"), "identity": .object(["name": .string(name)])])]),
            "defaultId": .string("main"),
        ])
    }

    @Test func selectingOnOneAgentPageDoesNotChangeAnotherGatewaysRenderedPet() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let home = self.gateway("Home", defaults: scratch.defaults)
        let work = self.gateway("Work", defaults: scratch.defaults)
        self.loadMainAgent(home, name: "Home Claw")
        self.loadMainAgent(work, name: "Work Claw")
        let homeAgent = AgentSummary(id: "main", name: "Home Claw")
        let workAgent = AgentSummary(id: "main", name: "Work Claw")

        AvatarCharacterRow.selectCreature("cat", agentId: "main", gateways: [home], defaults: scratch.defaults)
        #expect(home.queuedAvatarChoices["main"] == .some("cat"), "the selected agent page writes only Home's Gateway preference")
        #expect(work.queuedAvatarChoices["main"] == nil)
        AvatarCharacterRow.selectCreature("owl", agentId: "main", gateways: [work], defaults: scratch.defaults)
        #expect(work.queuedAvatarChoices["main"] == .some("owl"))

        #expect(AvatarSettings.style(for: homeAgent, in: home, defaults: scratch.defaults).creature == .cat,
                "the Home agent page keeps its selected creature after Work chooses another")
        #expect(AvatarSettings.style(for: workAgent, in: work, defaults: scratch.defaults).creature == .owl)
    }

    @Test func settingsRowsAreScopedToEachGatewayAgentPair() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let home = self.gateway("Home", defaults: scratch.defaults)
        let work = self.gateway("Work", defaults: scratch.defaults)
        self.loadMainAgent(home, name: "Claw")
        self.loadMainAgent(work, name: "Claw")

        let rows = AvatarSettingsSection.settingRows(for: [home, work])
        #expect(rows.count == 2, "Settings must expose one choice for each Gateway's copy of main")
        #expect(rows.allSatisfy { $0.gateways.count == 1 }, "each row edits only its owning Gateway")
        #expect(Set(rows.flatMap(\.gateways).map(\.id)) == Set([home.id, work.id]))
    }
}
