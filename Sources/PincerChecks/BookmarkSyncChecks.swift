import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// Bookmarks sync through `users.prefs` (#382): toggling one in the demo writes its shard of
/// `pincer.bookmarks.<n>` with `users.prefs.set`, and it round-trips back through a pull.
@MainActor
func runDemoBookmarkSync() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = AppModel(defaults: defaults)
    let gateway = app.add(.demo(), secret: nil)
    defer { BookmarkStore.shared(gatewayId: gateway.id).removeAll() }
    let keys = (0..<Bookmark.shardCount).map { gateway.syncedMap(Bookmark.prefKey(shard: $0)).syncedDefaultsKey }
    let ready = await waitFor("bookmark demo first sync") {
        gateway.state.isConnected && keys.allSatisfy { defaults.bool(forKey: $0) }
    }
    check(ready, "bookmark demo: connected and every bookmark shard first-synced")
    guard ready else { return }

    func stored(_ shard: Int) async -> [String: String] {
        let pref = Bookmark.prefKey(shard: shard)
        let result = try? await gateway.connection.request("users.prefs.get", ["keys": [.string(pref)]])
        return (result?["entries"]?[pref]?.object ?? [:]).compactMapValues(\.string)
    }

    let store = BookmarkStore.shared(gatewayId: gateway.id)
    let item = Bookmark(sessionKey: DemoBookmarks.tripSessionKey, messageId: "sync-check-1",
                        preview: "Synced through users.prefs", role: "assistant")
    let shard = Bookmark.shard(ofKey: item.id)
    check(store.toggle(item), "bookmark demo: toggling stars the message")
    var written = false
    for _ in 0..<50 where !written {
        written = await stored(shard)[item.id] == item.syncedValue
        if !written { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(written, "bookmark demo: the bookmark is written to pincer.bookmarks.\(shard) by users.prefs.set")
    let demoValue = await stored(shard)[item.id].flatMap { Bookmark(syncedKey: item.id, value: $0) }
    check(demoValue?.id == item.id && demoValue?.role == item.role && demoValue?.preview == item.preview, "bookmark demo: the stored value decodes back to the bookmark")
    check(defaults.data(forKey: GatewayStore.pendingPrefsKey(gateway.id)) == nil, "bookmark demo: nothing left pending")

    // Round trip: forget it locally without pushing, then a pull brings it back from the gateway.
    store.removeAll()
    check(!store.isBookmarked(sessionKey: item.sessionKey, messageId: item.messageId), "bookmark demo: cleared locally")
    await gateway.pull(gateway.syncedMap(Bookmark.prefKey(shard: shard)))
    check(store.isBookmarked(sessionKey: item.sessionKey, messageId: item.messageId),
          "bookmark demo: the bookmark comes back from users.prefs")

    // Relaunch: the demo's prefs start over, but the seeded bookmarks come back with them.
    let relaunched = GatewayStore(profile: .demo(), defaults: defaults)
    relaunched.start()
    let back = await waitFor("bookmark demo relaunch") { relaunched.state.isConnected && relaunched.bookmarkStore.bookmarks.count >= 3 }
    check(back, "bookmark demo: a relaunched demo still has its seeded bookmarks (\(relaunched.bookmarkStore.bookmarks.count))")
    relaunched.stop()

    // Un-starring deletes the entry remotely.
    check(!store.toggle(item), "bookmark demo: toggling again un-stars it")
    var deleted = false
    for _ in 0..<50 where !deleted {
        deleted = await stored(shard)[item.id] == nil
        if !deleted { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(deleted, "bookmark demo: un-starring deletes the entry from users.prefs")
    #else
    print("  skipped: needs @testable access to PincerKit (debug builds)")
    #endif
}
