import Foundation
import Testing
@testable import PincerKit

/// #275: our own `users.prefs.set` echo is recognised by count, not by a time window.
@MainActor
@Suite("Own users.prefs echoes", .serialized)
struct PrefsEchoTests {
    let pref = PrefsHarness.pref

    @Test func ownWriteEchoDoesNotPull() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        let before = h.gateway.gets
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        let echoed = await eventually { h.gateway.echoesSent == 1 }
        #expect(echoed)
        await h.settle()
        #expect(h.gateway.gets == before, "our own echo must not be read back")
        #expect(h.store.serverNameOverrides["k"] == "v")
    }

    @Test func anotherDevicesChangeRightAfterOurWritePulls() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        let before = h.gateway.gets
        h.store.serverNameOverrides["k"] = "v"
        await h.store.push(h.map, "k", "v")
        // Well inside the old 3 s window.
        h.gateway.externalChange(pref, ["k": "v", "theirs": "t"])
        let pulled = await eventually { h.store.serverNameOverrides["theirs"] == "t" }
        #expect(pulled, "a change by another device is not mistaken for our echo")
        #expect(h.gateway.gets == before + 1)
    }

    @Test func eachOwnWriteConsumesExactlyOneEcho() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        let before = h.gateway.gets
        // Back to back, so later writes start before earlier echoes are read.
        var pushes: [Task<Void, Never>] = []
        for index in 0..<3 {
            h.store.serverNameOverrides["k\(index)"] = "v"
            pushes.append(Task { await h.store.push(h.map, "k\(index)", "v") })
        }
        for push in pushes { await push.value }
        let echoed = await eventually { h.gateway.echoesSent >= 1 && h.gateway.echoesSent == h.gateway.sets.count }
        #expect(echoed)
        await h.settle()
        #expect(h.gateway.gets == before)
        h.gateway.externalChange(pref, ["k0": "v", "k1": "v", "k2": "v", "theirs": "t"])
        let pulled = await eventually { h.store.serverNameOverrides["theirs"] == "t" }
        #expect(pulled)
    }

    @Test func failedSetLeavesNoExpectedEchoBehind() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .error
        await h.store.push(h.map, "k", "v")
        h.gateway.externalChange(pref, ["theirs": "t"])
        let pulled = await eventually { h.store.serverNameOverrides["theirs"] == "t" }
        #expect(pulled, "the next changed event pulls")
    }

    @Test func conflictedSetLeavesNoExpectedEchoBehindAndPullsTheMap() async throws {
        let h = try await PrefsHarness()
        defer { h.finish() }
        h.gateway.setReply = .conflict
        h.gateway.seed(pref, ["theirs": "t"])
        let before = h.gateway.gets
        await h.store.push(h.map, "k", "v")
        #expect(h.gateway.gets > before, "a conflict re-reads the map")
        h.gateway.externalChange(pref, ["theirs": "t2"])
        let pulled = await eventually { h.store.serverNameOverrides["theirs"] == "t2" }
        #expect(pulled)
    }
}
