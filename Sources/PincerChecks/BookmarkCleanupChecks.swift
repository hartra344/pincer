import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runBookmarkCleanupChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Bookmark checks", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil
    defer { gateway.stop(); BookmarkStore.forget(gatewayId: gateway.id); defaults.removePersistentDomain(forName: suite) }
    let store = gateway.bookmarkStore
    for key in ["deleted", "kept", "local", "orphan"] {
        store.add(Bookmark(sessionKey: key, messageId: "saved", preview: key))
    }
    await gateway.forgetTranscript("kept")
    check(store.isBookmarked(sessionKey: "kept", messageId: "saved"), "clearing a transcript cache preserves its bookmarks")
    await gateway.transcriptChanged(key: "deleted", change: .deleted)
    check(!store.isBookmarked(sessionKey: "deleted", messageId: "saved"), "confirmed chat deletion removes its bookmarks")
    gateway.setSession(SessionRow(["key": "local"]), for: "local")
    await gateway.forgetOrphanedBookmarks(keeping: ["kept"])
    check(Set(store.bookmarks.map(\.sessionKey)) == ["kept", "local"], "complete-list cleanup preserves listed and locally pending chats")
    check(BookmarkStore(gatewayId: gateway.id, defaults: defaults).bookmarks == store.bookmarks, "confirmed deletion persists the remaining bookmarks")
    check(Bookmark.chatTitle(nil, sessionKey: "agent:main:dashboard:uuid") == L("Saved chat")
          && Bookmark.chatTitle("Kyoto trip", sessionKey: "anything") == "Kyoto trip", "unloaded bookmark labels are friendly and loaded labels stay intact")
    var listRequests = 0
    let missedKeys = await GatewayStore.completeSessionKeys(maxPages: 2) { _ in
        listRequests += 1
        if listRequests == 1 {
            return ["sessions": [["key": "a"], ["key": "b"]], "hasMore": true, "nextOffset": 2, "totalCount": 3]
        }
        return ["sessions": [["key": "b"]], "hasMore": false, "totalCount": 3]
    }
    check(missedKeys == nil, "a page walk missing a reported chat cannot authorize bookmark deletion")
    store.onChange = { _ in
        store.onChange = nil
        store.add(Bookmark(sessionKey: "new", messageId: "saved", preview: "A newer edit"))
    }
    await store.removeConfirmedSessions(["kept"])
    check(store.isBookmarked(sessionKey: "new", messageId: "saved")
          && BookmarkStore(gatewayId: gateway.id, defaults: defaults).bookmarks == store.bookmarks,
          "off-main deletion encoding cannot overwrite a newer local bookmark edit")
    #else
    print("  skipped: needs @testable access to PincerKit (debug builds)")
    #endif
}
