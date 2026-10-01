import Foundation
import Testing
@testable import PincerKit

/// A real `GatewayStore` connected to a `FakePrefsGateway`, with its prefs first-synced.
@MainActor
struct PrefsHarness {
    let gateway: FakePrefsGateway
    let scratch = ScratchDefaults()
    let profile: GatewayProfile
    let store: GatewayStore

    static let pref = GatewayStore.serverNamesPref

    private let ownsGateway: Bool

    init(seed: [String: [String: String]] = [:], sharing shared: FakePrefsGateway? = nil) async throws {
        self.ownsGateway = shared == nil
        self.gateway = try shared ?? FakePrefsGateway()
        for (pref, entries) in seed { self.gateway.seed(pref, entries) }
        self.profile = GatewayProfile(name: "Prefs", url: self.gateway.url, authMode: .none)
        self.store = Self.makeStore(self.profile, self.scratch.defaults)
        self.store.start()
        let keys = self.store.syncedMaps.map(\.syncedDefaultsKey)
        let defaults = self.scratch.defaults
        let isSynced = { self.store.state.isConnected && keys.allSatisfy { defaults.bool(forKey: $0) } }
        // Long enough for the store's own bootstrap-pull retries when the start of a parallel run starves it.
        let synced = await eventually(timeout: .seconds(90), isSynced)
        let unsynced = keys.filter { !defaults.bool(forKey: $0) }
        try #require(synced, "the store connects and first-syncs users.prefs (state: \(self.store.state), gets: \(self.gateway.gets), unsynced: \(unsynced.count))")
    }

    static func makeStore(_ profile: GatewayProfile, _ defaults: UserDefaults) -> GatewayStore {
        GatewayStore(profile: profile, defaults: defaults, identity: Fixtures.identity())
    }

    var map: GatewayStore.SyncedMap { self.store.syncedMap(Self.pref) }

    func finish() {
        self.store.stop()
        if self.ownsGateway { self.gateway.stop() }
        self.scratch.remove()
    }

    /// Lets the store process events already on the wire; for asserting that nothing happens.
    func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
}

@MainActor
@Suite("Failed prefs writes stay pending (#245)", .serialized)
struct PrefsWriteFailureTests {
    @Test func failedSetStaysPendingAndASetErrorDoesNotDropIt() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref]?["k"] == .some("v"))
        #expect(h.gateway.map(PrefsHarness.pref)?["k"] == nil)
    }

    @Test func failedFirstReadIsRetriedWithoutReconnecting() async throws {
        let gateway = try FakePrefsGateway()
        gateway.failingGets = 2
        let h = try await PrefsHarness(sharing: gateway)
        defer {
            h.finish()
            gateway.stop()
        }
        #expect(h.gateway.gets >= 2)
    }

    @Test func conflictedSetStaysPending() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .conflict
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref]?["k"] == .some("v"))
    }

    @Test func laterPullDoesNotRevertTheLocalValue() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        await h.store.pull(h.map)
        #expect(h.store.serverNameOverrides["k"] == "v")
    }

    @Test func nextPushRetriesTheEarlierFailureAndClearsPending() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        h.gateway.setReply = .ok
        h.store.serverNameOverrides["k2"] = "v2"
        await h.store.push(h.map, "k2", "v2")
        #expect(h.gateway.map(PrefsHarness.pref) == ["k": "v", "k2": "v2"])
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref] == nil)
        #expect(h.scratch.defaults.data(forKey: "pincer.prefsPending.\(h.profile.id.uuidString)") == nil)
    }

    @Test func reconnectPullRetriesLeftoverEntries() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        h.gateway.setReply = .ok
        await h.store.pullBootstrapPrefs(epoch: h.store.connectionEpoch)
        let written = await eventually { h.gateway.map(PrefsHarness.pref)?["k"] == "v" }
        #expect(written, "the pull after reconnect re-pushes what never landed")
        let cleared = await eventually { h.store.pendingPrefChanges[PrefsHarness.pref] == nil }
        #expect(cleared)
        #expect(h.store.serverNameOverrides["k"] == "v")
    }

    @Test func pendingDeleteIsRetriedToo() async throws {
        let h = try await PrefsHarness(seed: [PrefsHarness.pref: ["gone": "x"]])
        defer { h.finish() }
        h.gateway.setReply = .error
        h.store.serverNameOverrides["gone"] = nil
        await h.store.push(h.map, "gone", nil)
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref]?["gone"] == .some(nil))
        h.gateway.setReply = .ok
        await h.store.pullBootstrapPrefs(epoch: h.store.connectionEpoch)
        let removed = await eventually { h.gateway.map(PrefsHarness.pref)?["gone"] == nil && h.store.pendingPrefChanges.isEmpty }
        #expect(removed)
        #expect(h.store.serverNameOverrides["gone"] == nil)
    }

    @Test func eachPushSendsEveryPendingEntry() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        await h.store.push(h.map, "a", "1")
        h.gateway.setReply = .ok
        await h.store.push(h.map, "b", "2")
        let last = h.gateway.sets.last?["entries"]?[PrefsHarness.pref]
        #expect(last?["a"]?.string == "1")
        #expect(last?["b"]?.string == "2")
    }

    @Test func rejectedSetIsRecordedStaysPendingAndClearsOnSuccess() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        await h.store.push(h.map, "k", "v")
        #expect(h.store.rejectedPrefs[PrefsHarness.pref] != nil)
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref]?["k"] == .some("v"))
        let sent = h.gateway.sets.count
        await h.settle()
        #expect(h.gateway.sets.count == sent, "a rejected write isn't looped")
        h.gateway.setReply = .ok
        await h.store.push(h.map, "k2", "v2")
        #expect(h.store.rejectedPrefs[PrefsHarness.pref] == nil)
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref] == nil)
    }

    @Test func rejectedLegacySetIsRecordedStaysPendingAndClearsOnSuccess() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.store.prefsSupportsExpected = false
        h.gateway.setReply = .error

        await h.store.push(h.map, "k", "v")

        #expect(h.gateway.sets.last?["expectedEntries"] == nil, "legacy writes omit compare-and-set")
        #expect(h.store.rejectedPrefs[PrefsHarness.pref] == "rejected", "the Gateway rejection is visible")
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref]?["k"] == .some("v"))

        h.gateway.setReply = .ok
        await h.store.push(h.map, "k2", "v2")
        #expect(h.store.rejectedPrefs[PrefsHarness.pref] == nil, "a successful retry clears the rejection")
        #expect(h.store.pendingPrefChanges[PrefsHarness.pref] == nil)
    }

    // MARK: Persistence

    @Test func pendingSurvivesANewStoreWithTheSameIdAndDefaults() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        await h.store.push(h.map, "k", "v")
        await h.store.push(h.map, "gone", nil)
        #expect(h.scratch.defaults.data(forKey: "pincer.prefsPending.\(h.profile.id.uuidString)") != nil)
        let reborn = PrefsHarness.makeStore(h.profile, h.scratch.defaults)
        #expect(reborn.pendingPrefChanges[PrefsHarness.pref]?["k"] == .some("v"))
        #expect(reborn.pendingPrefChanges[PrefsHarness.pref]?["gone"] == .some(nil))
    }

    @Test func pendingIsPerGateway() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        await h.store.push(h.map, "k", "v")
        let other = GatewayProfile(name: "Other", url: "ws://127.0.0.1:1", authMode: .none)
        #expect(PrefsHarness.makeStore(other, h.scratch.defaults).pendingPrefChanges.isEmpty)
    }

    @Test func avatarChoicesQueuedWhileDisconnectedSurviveANewStore() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none)
        let store = PrefsHarness.makeStore(profile, scratch.defaults)
        store.setAvatarCreature(.cat, for: "main")
        store.setAvatarRenderStyle(.plush)
        let reborn = PrefsHarness.makeStore(profile, scratch.defaults)
        // Offline choices stay queued, not applied, until the Gateway is reached.
        #expect(reborn.queuedAvatarChoices["main"] == .some("cat"))
        #expect(reborn.queuedAvatarChoices[AvatarPreferences.renderStyleEntry] == .some("plush"))
    }

    @Test func queuedAvatarChoicesReachTheGatewayAfterARelaunch() async throws {
        let gateway = try FakePrefsGateway()
        defer { gateway.stop() }
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Relaunch", url: gateway.url, authMode: .none)
        // The first launch can't reach the Gateway: the choice is made, then the app quits.
        let offline = GatewayProfile(id: profile.id, name: "Relaunch", url: "ws://127.0.0.1:1", authMode: .none)
        PrefsHarness.makeStore(offline, scratch.defaults).setAvatarCreature(.cat, for: "main")
        let store = PrefsHarness.makeStore(profile, scratch.defaults)
        store.start()
        defer { store.stop() }
        let landed = await eventually(timeout: .seconds(30)) {
            gateway.map(AvatarPreferences.prefKey)?["main"] == "cat"
        }
        #expect(landed)
        #expect(store.avatarChoices["main"] == "cat")
    }
}
