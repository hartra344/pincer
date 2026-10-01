import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Bookmark cleanup", .serialized)
struct BookmarkCleanupTests {
    @Test func confirmedDeletionRemovesOnlyThatChatsBookmarks() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); BookmarkStore.forget(gatewayId: gateway.id); scratch.remove() }
        let bookmarks = gateway.bookmarkStore
        bookmarks.add(Bookmark(sessionKey: "agent:main:deleted", messageId: "one", preview: "Deleted chat"))
        bookmarks.add(Bookmark(sessionKey: "agent:main:kept", messageId: "two", preview: "Kept chat"))
        await gateway.transcriptChanged(key: "agent:main:deleted", change: .deleted)
        #expect(bookmarks.bookmarks.map(\.sessionKey) == ["agent:main:kept"])
        #expect(BookmarkStore(gatewayId: gateway.id, defaults: scratch.defaults).bookmarks == bookmarks.bookmarks)
    }

    @Test func droppingACachePreservesBookmarks() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); BookmarkStore.forget(gatewayId: gateway.id); scratch.remove() }
        let bookmarks = gateway.bookmarkStore
        let item = Bookmark(sessionKey: "agent:main:kept", messageId: "one", preview: "Keep this")
        bookmarks.add(item)
        await gateway.forgetTranscript(item.sessionKey)
        #expect(bookmarks.bookmarks == [item])
    }

    @Test func completeListCleansOfflineOrphansButPreservesLocalChats() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop(); BookmarkStore.forget(gatewayId: gateway.id); scratch.remove() }
        let store = gateway.bookmarkStore
        for key in ["listed", "orphan", "local"] {
            store.add(Bookmark(sessionKey: key, messageId: "one", preview: key))
        }
        gateway.setSession(SessionRow(["key": "local"]), for: "local")
        await gateway.forgetOrphanedBookmarks(keeping: ["listed"])
        #expect(Set(store.bookmarks.map(\.sessionKey)) == ["listed", "local"])
        #expect(BookmarkStore(gatewayId: gateway.id, defaults: scratch.defaults).bookmarks == store.bookmarks)
    }

    @Test func deletionEncodingCannotOverwriteANewerLocalEdit() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let id = UUID()
        let store = BookmarkStore(gatewayId: id, defaults: scratch.defaults)
        store.add(Bookmark(sessionKey: "deleted", messageId: "one", preview: "Remove"))
        store.add(Bookmark(sessionKey: "kept", messageId: "two", preview: "Keep"))
        store.onChange = { _ in
            store.onChange = nil
            store.add(Bookmark(sessionKey: "new", messageId: "three", preview: "New local edit"))
        }
        await store.removeConfirmedSessions(["deleted"])
        #expect(Set(store.bookmarks.map(\.sessionKey)) == ["kept", "new"])
        #expect(BookmarkStore(gatewayId: id, defaults: scratch.defaults).bookmarks == store.bookmarks)
    }

    @Test func unloadedBookmarkChatHasAFriendlyLabel() {
        let key = "agent:main:dashboard:8b212707-4690-4edb-9119-9f6e4f0a2c7b"
        #expect(Bookmark.chatTitle(nil, sessionKey: key) == L("Saved chat"))
        #expect(Bookmark.chatTitle("Kyoto trip", sessionKey: key) == "Kyoto trip")
    }
}
