import Foundation
import PincerKit

@MainActor
func runRejectedPrefHealthChecks() {
    let rows = RejectedPrefHealthRow.rows(from: [
        "pincer.serverNames": "Gateway rejected this preference",
        Bookmark.prefKey(shard: 3): "bookmark shard is too large",
        Reactions.prefKey: "invalid reaction map",
    ])
    check(rows.map(\.id) == [Bookmark.prefKey(shard: 3), Reactions.prefKey, "pincer.serverNames"],
          "Gateway Health rows sort by stable preference identity")
    check(rows.map(\.feature) == [.bookmarks, .reactions, .serverNames],
          "Gateway Health rows name the rejected feature")
    check(rows.map(\.message) == ["bookmark shard is too large", "invalid reaction map",
                                   "Gateway rejected this preference"],
          "Gateway Health rows preserve each Gateway message")
    check(RejectedPrefHealthRow.rows(from: [:]).isEmpty,
          "accepted retries remove the corresponding Health row")
}

@MainActor
func runDemoRejectedPrefWriteChecks() async {
    await withCacheEnvironment("off") {
        let (defaults, suite) = scratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.start()
        defer {
            gateway.stop()
            defaults.removePersistentDomain(forName: suite)
        }

        let pref = "pincer.chatColors"
        let key = "agent:main:pref-health-check"
        let ready = await waitFor("demo synced color preferences") {
            gateway.state.isConnected && gateway.hasSyncedPreference(pref)
        }
        check(ready, "demo rejected preference: chat colors have first-synced")
        guard ready else { return }

        let oversized = String(repeating: "x", count: 5_000)
        gateway.setColor(oversized, for: key)
        let rejected = await waitFor("demo oversized preference rejection") {
            gateway.rejectedPrefs[pref] != nil
        }
        let expectedMessage = "invalid users.prefs.set entry for \(pref): value-too-large"
        check(rejected && gateway.rejectedPrefs[pref] == expectedMessage,
              "demo rejected preference: Health retains the exact Gateway error message")
        check(gateway.rejectedPrefHealthRows.contains(where: {
            $0.id == pref && $0.feature == .chatColors && $0.message == expectedMessage
        }), "demo rejected preference: the Health projection identifies chat colors")
        check(gateway.customColor(for: key) == oversized,
              "demo rejected preference: the optimistic color edit remains visible")

        gateway.setColor("#336699", for: key)
        let retried = await waitFor("demo accepted preference retry") {
            gateway.rejectedPrefs[pref] == nil && gateway.customColor(for: key) == "#336699"
                && gateway.rejectedPrefHealthRows.isEmpty
        }
        check(retried, "demo rejected preference: an accepted edit clears the Health row")

        await checkDemoPreferenceBoundaries()
    }
}

@MainActor
private func checkDemoPreferenceBoundaries() async {
    let connection = GatewayConnection(profile: .demo())
    let connected = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in connected.value = true } }
    })
    await connection.start()
    let ready = await waitFor("raw demo prefs boundary connection") { connected.value }
    check(ready, "raw demo connection is ready for preference limit checks")
    guard ready else { await connection.stop(); return }

    let acceptedBatch = Dictionary(uniqueKeysWithValues: (0..<32).map {
        ("pincer.health-boundary-\($0)", JSONValue.string("ok"))
    })
    let accepted32 = try? await connection.request("users.prefs.set", ["entries": .object(acceptedBatch)])
    check(accepted32?["status"]?.string == "ok", "demo prefs accepts the upstream 32-entry set limit")

    let rejectedBatch = Dictionary(uniqueKeysWithValues: (32..<65).map {
        ("pincer.health-boundary-\($0)", JSONValue.string("ok"))
    })
    var rejected33 = false
    do {
        _ = try await connection.request("users.prefs.set", ["entries": .object(rejectedBatch)])
    } catch let GatewayError.rpc(code, message, _) {
        rejected33 = code == "INVALID_REQUEST" && message == "invalid users.prefs.set entry: invalid-entry-count"
    } catch {}
    check(rejected33, "demo prefs rejects 33 entries with the upstream invalid-entry-count response")

    let current = try? await connection.request("users.prefs.get", [:])
    let currentCount = current?["entries"]?.object?.count ?? 0
    let profileKeysNeeded = max(0, 128 - currentCount)
    var filledProfile = current != nil
    for start in stride(from: 0, to: profileKeysNeeded, by: 32) {
        let end = min(start + 32, profileKeysNeeded)
        let batch = Dictionary(uniqueKeysWithValues: (start..<end).map {
            ("pincer.health-profile-\($0)", JSONValue.string("ok"))
        })
        let result = try? await connection.request("users.prefs.set", ["entries": .object(batch)])
        if result?["status"]?.string != "ok" { filledProfile = false; break }
    }
    check(filledProfile, "demo prefs fills exactly to the upstream 128-key profile cap")
    var rejectedProfileLimit = false
    do {
        _ = try await connection.request("users.prefs.set", [
            "entries": .object(["pincer.health-profile-overflow": .string("ok")]),
        ])
    } catch let GatewayError.rpc(code, message, details) {
        rejectedProfileLimit = code == "INVALID_REQUEST"
            && message == "users.prefs.set exceeds the 128-key profile limit (current count: 128)"
            && details?["code"]?.string == "USER_PREFS_LIMIT_EXCEEDED"
            && details?["limit"]?.int == 128
            && details?["currentCount"]?.int == 128
    } catch {}
    check(rejectedProfileLimit, "demo prefs reports the upstream profile-key limit message and details")
    await connection.stop()
}
