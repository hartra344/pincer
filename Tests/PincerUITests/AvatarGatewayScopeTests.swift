import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #518: two Gateways may use the same agent id while keeping different synced avatar choices.
@MainActor
@Suite("Avatar choices per Gateway")
struct AvatarGatewayScopeTests {
    private func gateway(_ name: String, defaults: UserDefaults, id: UUID = UUID()) -> GatewayStore {
        GatewayStore(
            profile: GatewayProfile(id: id, name: name, url: "ws://127.0.0.1:1", authMode: .none),
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

        #expect(scratch.defaults.string(forKey: AvatarPreferences.creatureKey(for: "main")) == nil,
                "new selections must not overwrite the legacy global character")
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
        #expect(Set(rows.map(\.gateway.id)) == Set([home.id, work.id]), "each row edits only its owning Gateway")
        #expect(Set(rows.map { $0.gateway.profile.name }) == Set(["Home", "Work"]))
        #expect(Set(rows.map(\.id)) == Set(["\(home.id.uuidString):main", "\(work.id.uuidString):main"]))
    }

    @Test func clearingToAutoAndReopeningKeepsChoicesGatewayScoped() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let homeID = UUID()
        let workID = UUID()
        scratch.defaults.set("cat", forKey: AvatarPreferences.creatureKey(for: "main"))
        let home = self.gateway("Home", defaults: scratch.defaults, id: homeID)
        let work = self.gateway("Work", defaults: scratch.defaults, id: workID)

        #expect(home.avatarChoices["main"] == "cat", "a profile without saved choices imports the legacy device value once")
        work.avatarChoices["main"] = "owl"
        #expect(home.avatarCreature(for: "main") == .cat)
        #expect(work.avatarCreature(for: "main") == .owl)

        home.setAvatarCreature(nil, for: "main")
        #expect(home.avatarCreature(for: "main") == nil, "Auto clears the Home override")
        #expect(work.avatarCreature(for: "main") == .owl, "clearing Home does not change Work")

        // Simulate the Gateway accepting the queued Auto choice before reopening its profile.
        home.avatarChoices["main"] = nil
        home.queuedAvatarChoices = [:]

        let reopenedHome = self.gateway("Home", defaults: scratch.defaults, id: homeID)
        let reopenedWork = self.gateway("Work", defaults: scratch.defaults, id: workID)
        #expect(reopenedHome.avatarCreature(for: "main") == nil)
        #expect(reopenedWork.avatarCreature(for: "main") == .owl)
    }
}
