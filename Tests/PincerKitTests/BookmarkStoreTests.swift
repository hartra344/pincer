import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Bookmarks")
struct BookmarkStoreTests {
    let suite = "pincer.tests.bookmarks.\(UUID().uuidString)"
    let gateway = UUID()

    var defaults: UserDefaults { UserDefaults(suiteName: self.suite)! }

    func bookmark(_ id: String, session: String = "main", at seconds: TimeInterval = 0) -> Bookmark {
        Bookmark(sessionKey: session, messageId: id, preview: "Message \(id)", createdAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func toggleAddsAndRemoves() {
        let store = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        #expect(store.toggle(self.bookmark("a")))
        #expect(store.isBookmarked(sessionKey: "main", messageId: "a"))
        #expect(!store.toggle(self.bookmark("a")))
        #expect(!store.isBookmarked(sessionKey: "main", messageId: "a"))
        #expect(store.bookmarks.isEmpty)
    }

    @Test func addIgnoresDuplicatesAndOrdersNewestFirst() {
        let store = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        store.add(self.bookmark("a"))
        store.add(self.bookmark("b", session: "other"))
        store.add(self.bookmark("a"))
        #expect(store.bookmarks.map(\.messageId) == ["b", "a"])
        #expect(store.bookmarks(in: "main").map(\.messageId) == ["a"])
        store.remove(sessionKey: "main", messageId: "a")
        #expect(store.bookmarks.map(\.messageId) == ["b"])
        store.removeAll(sessionKey: "other")
        #expect(store.bookmarks.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let first = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        first.add(self.bookmark("a", at: 5))
        first.add(self.bookmark("b", at: 6))
        let second = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        #expect(second.bookmarks == first.bookmarks)
        #expect(second.isBookmarked(sessionKey: "main", messageId: "b"))
        second.removeAll()
        #expect(BookmarkStore(gatewayId: self.gateway, defaults: self.defaults).bookmarks.isEmpty)
    }

    @Test func gatewaysAreIsolated() {
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let one = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        let two = BookmarkStore(gatewayId: UUID(), defaults: self.defaults)
        one.add(self.bookmark("a"))
        #expect(two.bookmarks.isEmpty)
        #expect(BookmarkStore(gatewayId: two.gatewayId, defaults: self.defaults).bookmarks.isEmpty)
    }

    @Test func toggleFromChatItemUsesTranscriptId() async {
        let store = BookmarkStore(gatewayId: self.gateway, defaults: self.defaults)
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        var item = ChatItem(id: "local", role: .assistant, blocks: [.text("Hello\nworld")])
        item.transcriptId = "t-9"
        #expect(store.toggle(item, sessionKey: "main"))
        #expect(store.isBookmarked(sessionKey: "main", messageId: "t-9"))
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.first?.preview == "Hello world")
        #expect(store.bookmarks.first?.role == "assistant")
    }

    @Test func previewIsOneLineAndTruncated() {
        #expect(Bookmark.preview("  one \n\n two  ") == "one two")
        let long = Bookmark.preview(String(repeating: "a", count: 500))
        #expect(long.count == Bookmark.previewLength)
        #expect(long.hasSuffix("…"))
        #expect(Bookmark.preview(String(repeating: "a", count: 160)).count == 160)
    }
}
