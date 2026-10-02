import Foundation
import Testing
@testable import PincerKit

@Suite("Avatar seed entries")
struct AvatarSeedEntryTests {
    func scratch() -> UserDefaults {
        let name = "AvatarSeedEntryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func entryHelpersRoundTrip() {
        #expect(AvatarPreferences.seedEntryPrefix == "seed@")
        #expect(AvatarPreferences.seedEntry(for: "main") == "seed@main")
        #expect(AvatarPreferences.agentId(fromSeedEntry: "seed@main") == "main")
        #expect(AvatarPreferences.agentId(fromSeedEntry: "main") == nil)
        #expect(AvatarPreferences.agentId(fromSeedEntry: AvatarPreferences.renderStyleEntry) == nil)
    }

    @Test func applySkipsSeedEntries() {
        let defaults = self.scratch()
        let map = ["seed@main": "Claw|main", "main": "cat", AvatarPreferences.renderStyleEntry: "plush"]
        AvatarPreferences.apply(map, previous: [:], to: defaults)
        #expect(defaults.string(forKey: AvatarPreferences.creatureKey(for: "main")) == "cat")
        #expect(defaults.object(forKey: AvatarPreferences.creatureKey(for: "seed@main")) == nil)
        AvatarPreferences.apply([:], previous: map, to: defaults)
        #expect(defaults.object(forKey: AvatarPreferences.creatureKey(for: "seed@main")) == nil)
    }

    @Test func localIgnoresSeedLookalikes() {
        let defaults = self.scratch()
        defaults.set("cat", forKey: AvatarPreferences.creatureKey(for: "main"))
        defaults.set("Claw|main", forKey: AvatarPreferences.creatureKey(for: "seed@main"))
        #expect(AvatarPreferences.local(in: defaults) == ["main": "cat"])
    }
}

@MainActor
@Suite("Avatar seeds per Gateway")
struct AvatarSeedStoreTests {
    let scratch = ScratchDefaults()

    func store(_ name: String = "Test") -> GatewayStore {
        let profile = GatewayProfile(name: name, url: "ws://127.0.0.1:1", authMode: .none)
        return GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
    }

    static func agentsResult(_ agents: [(String, String)]) -> JSONValue {
        let list = agents.map { id, name -> JSONValue in
            ["id": .string(id), "identity": ["name": .string(name)]]
        }
        return ["agents": .array(list), "defaultId": .string(agents.first?.0 ?? "main")]
    }

    /// Applies agents and simulates confirmed prefs-read completion without opening a Gateway.
    func load(_ store: GatewayStore, _ agents: [(String, String)]) async {
        store.applyAgents(Self.agentsResult(agents))
        store.finishBootstrapPrefsPull(epoch: store.connectionEpoch, readSucceeded: true)
    }

    static func agent(_ id: String, _ name: String) -> AgentSummary { AgentSummary(id: id, name: name) }

    /// The failing repro for #145: a rename used to re-seed the pet.
    @Test func renameKeepsThePet() async {
        defer { self.scratch.remove() }
        let store = self.store()
        await self.load(store, [("main", "Claw")])
        let before = AvatarStyle.seeded(from: store.avatarSeed(for: Self.agent("main", "Claw")))
        store.applyAgents(Self.agentsResult([("main", "Renamed Completely")]))
        let renamed = Self.agent("main", "Renamed Completely")
        let after = AvatarStyle.seeded(from: store.avatarSeed(for: renamed))
        #expect(after == before)
        #expect(after.creature == before.creature)
        #expect(store.avatarSeed(for: renamed) == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
    }

    @Test func unrecordedAgentFallsBackToItsIdentitySeed() {
        defer { self.scratch.remove() }
        let store = self.store()
        let agent = Self.agent("main", "Claw")
        #expect(store.avatarSeed(for: agent) == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
    }

    /// After this device's first sync, a new agent's seed waits for the connection's prefs pull.
    @Test func waitsForThePrefsPull() async {
        defer { self.scratch.remove() }
        let store = self.store()
        self.scratch.defaults.set(true, forKey: store.syncedMap(AvatarPreferences.prefKey).syncedDefaultsKey)
        store.applyAgents(Self.agentsResult([("main", "Claw")]))
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] == nil)
        store.finishBootstrapPrefsPull(epoch: store.connectionEpoch, readSucceeded: true)
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")]
            == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
    }

    /// A failed read on an already-synced Gateway must not authorize a new seed write.
    @Test func failedPrefsReadDoesNotPromoteAvatarSeedsForTheCurrentEpoch() {
        defer { self.scratch.remove() }
        let store = self.store()
        self.scratch.defaults.set(true, forKey: store.syncedMap(AvatarPreferences.prefKey).syncedDefaultsKey)
        store.applyAgents(Self.agentsResult([("new-agent", "Renamed Before This Device Saw It")]))

        store.finishBootstrapPrefsPull(epoch: store.connectionEpoch, readSucceeded: false)

        let seedEntry = AvatarPreferences.seedEntry(for: "new-agent")
        #expect(store.avatarPrefsPulledEpoch == nil)
        #expect(store.avatarChoices[seedEntry] == nil)
        #expect(store.pendingPrefChanges[AvatarPreferences.prefKey] == nil,
                "an automatic seed is neither recorded nor pushed without a successful read")
    }

    @Test func successfulEmptyProfileReadAuthorizesSeedsForTheCurrentEpoch() {
        defer { self.scratch.remove() }
        let store = self.store()
        self.scratch.defaults.set(true, forKey: store.syncedMap(AvatarPreferences.prefKey).syncedDefaultsKey)
        store.applyAgents(Self.agentsResult([("main", "Claw")]))

        // A successful users.prefs.get may omit pincer.avatars when the profile has no entries.
        store.finishBootstrapPrefsPull(epoch: store.connectionEpoch, readSucceeded: true)

        #expect(store.avatarPrefsPulledEpoch == store.connectionEpoch)
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")]
            == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
    }

    @Test func stalePrefsReadCannotPromoteAvatarSeeds() {
        defer { self.scratch.remove() }
        let store = self.store()
        self.scratch.defaults.set(true, forKey: store.syncedMap(AvatarPreferences.prefKey).syncedDefaultsKey)
        store.applyAgents(Self.agentsResult([("main", "Claw")]))

        store.finishBootstrapPrefsPull(epoch: store.connectionEpoch - 1, readSucceeded: true)

        #expect(store.avatarPrefsPulledEpoch == nil)
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] == nil)
        #expect(store.pendingPrefChanges[AvatarPreferences.prefKey] == nil)
    }

    /// Before the first sync, seeds are kept here for the first sync's merge to write (the
    /// Gateway's older seeds win there), so first launch writes `pincer.avatars` once.
    @Test func beforeFirstSyncSeedsAreKeptForTheMerge() {
        defer { self.scratch.remove() }
        let store = self.store()
        store.avatarChoices[AvatarPreferences.seedEntry(for: "coder")] = "Older|coder"
        store.applyAgents(Self.agentsResult([("main", "Claw"), ("coder", "Forge")]))
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")]
            == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "coder")] == "Older|coder")
        #expect(store.pendingPrefChanges[AvatarPreferences.prefKey] == nil)
    }

    @Test func recordsEveryNewAgentAndNeverOverwrites() async {
        defer { self.scratch.remove() }
        let store = self.store()
        await self.load(store, [("main", "Claw"), ("coder", "Forge")])
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "coder")] == AvatarStyle.identitySeed(name: "Forge", agentId: "coder"))
        store.applyAgents(Self.agentsResult([("main", "Other"), ("coder", "Smith"), ("new", "Nova")]))
        store.recordAvatarSeeds()
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] == AvatarStyle.identitySeed(name: "Claw", agentId: "main"))
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "coder")] == AvatarStyle.identitySeed(name: "Forge", agentId: "coder"))
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "new")] == AvatarStyle.identitySeed(name: "Nova", agentId: "new"))
    }

    @Test func existingGatewaySeedWins() async {
        defer { self.scratch.remove() }
        let store = self.store()
        store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] = "Original|main"
        await self.load(store, [("main", "Claw")])
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] == "Original|main")
        #expect(store.avatarSeed(for: Self.agent("main", "Claw")) == "Original|main")
    }

    @Test func seedsNeverReachDeviceDefaults() async {
        defer { self.scratch.remove() }
        let store = self.store()
        await self.load(store, [("main", "Claw")])
        #expect(self.scratch.defaults.object(forKey: AvatarPreferences.creatureKey(for: "seed@main")) == nil)
        #expect(AvatarPreferences.local(in: self.scratch.defaults)["seed@main"] == nil)
    }

    @Test func twoGatewaysKeepDifferentPetsForTheSameAgentId() async {
        defer { self.scratch.remove() }
        let home = self.store("Home")
        let work = self.store("Work")
        await self.load(home, [("main", "Claw")])
        await self.load(work, [("main", "Scout")])
        home.applyAgents(Self.agentsResult([("main", "Scout")]))
        let homeSeed = home.avatarSeed(for: Self.agent("main", "Scout"))
        let workSeed = work.avatarSeed(for: Self.agent("main", "Scout"))
        #expect(homeSeed != workSeed)
        #expect(AvatarStyle.seeded(from: homeSeed) != AvatarStyle.seeded(from: workSeed))
    }

    @Test func sameAgentCharacterLookupUsesTheOwningGatewayChoice() {
        defer { self.scratch.remove() }
        let home = self.store("Home")
        let work = self.store("Work")
        home.avatarChoices["main"] = AvatarCreature.cat.rawValue
        work.avatarChoices["main"] = AvatarCreature.owl.rawValue

        #expect(home.avatarCreature(for: "main") == .cat)
        #expect(work.avatarCreature(for: "main") == .owl)
    }

    @Test func deletingAnAgentClearsItsSeedAndCreature() async {
        defer { self.scratch.remove() }
        let store = self.store()
        await self.load(store, [("main", "Claw"), ("coder", "Forge")])
        store.avatarChoices["coder"] = "cat"
        store.clearAvatarChoices(for: "coder")
        #expect(store.avatarChoices["coder"] == nil)
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "coder")] == nil)
        #expect(store.avatarChoices[AvatarPreferences.seedEntry(for: "main")] != nil)
    }
}
