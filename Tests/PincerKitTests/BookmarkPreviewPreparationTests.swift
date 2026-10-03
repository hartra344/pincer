import Foundation
import Testing
@testable import PincerKit

/// Exact-ID, bounded records keep these causal probes isolated from other tests and stores.
private final class BookmarkPreparationRecords: @unchecked Sendable {
    private let lock = NSLock()
    private let id: String
    private var records: [Bool] = []

    init(id: String) { self.id = id }

    func record(id: String, onMain: Bool) {
        guard id == self.id else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.records.count < 4 { self.records.append(onMain) }
    }

    var snapshot: [Bool] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.records
    }
}

@MainActor
@Suite("Bookmark preview preparation")
struct BookmarkPreviewPreparationTests {
    @Test func actualChatItemTogglePreparesLargeMultiblockTextOffMain() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        var item = ChatItem(id: "local", role: .user,
                            blocks: [.text("  Opening line  "), .thinking("Excluded reasoning"),
                                     .text(String(repeating: "\n   Details 👨‍👩‍👧‍👦  ", count: 30_000))])
        item.transcriptId = "transcript"
        item.timestamp = Date(timeIntervalSince1970: 123)
        let records = BookmarkPreparationRecords(id: Bookmark.id(sessionKey: "main", messageId: "transcript"))
        store.previewPreparationProbe = { records.record(id: $0, onMain: $1) }

        #expect(store.toggle(item, sessionKey: "main"))
        #expect(store.isBookmarked(sessionKey: "main", messageId: "transcript"))
        #expect(!store.isBookmarked(sessionKey: "main", messageId: "local"))
        #expect(store.bookmarks.first?.role == "user")
        #expect(store.bookmarks.first?.messageDate == item.timestamp)
        await store.waitForPreviewPreparation()
        #expect(records.snapshot == [false], "Actual text joining and preview normalization must execute off-main")
        #expect(store.bookmarks.first?.preview == Bookmark.preview(item.plainText))
    }

    @Test func actualChatItemRemovalNeverJoinsOrNormalizesText() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        var item = ChatItem(id: "local", role: .assistant,
                            blocks: [.text(String(repeating: "large text\n", count: 50_000))])
        item.transcriptId = "transcript"
        let bookmark = Bookmark(sessionKey: "main", messageId: "transcript", preview: "Already saved")
        store.add(bookmark)
        let records = BookmarkPreparationRecords(id: bookmark.id)
        store.previewPreparationProbe = { records.record(id: $0, onMain: $1) }

        #expect(!store.toggle(item, sessionKey: "main"))
        #expect(!store.isBookmarked(sessionKey: "main", messageId: "transcript"))
        await store.waitForPreviewPreparation()
        #expect(records.snapshot.isEmpty, "Removing a star must not prepare the message text")
    }

    @Test func previewPreservesWhitespaceMultiblockAndUnicodeCharacterSemantics() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        let item = ChatItem(id: "semantics", role: .assistant,
                            blocks: [.text(" \tOne  two\r\n \n "), .thinking("Not preview text"),
                                     .text("  三 👨‍👩‍👧‍👦\n\tFour  ")])
        #expect(store.toggle(item, sessionKey: "main"))
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.first?.preview == "One  two 三 👨‍👩‍👧‍👦 Four")
        let grapheme = "👨‍👩‍👧‍👦"
        #expect(Bookmark.preview(String(repeating: grapheme, count: 160)) == String(repeating: grapheme, count: 160))
        #expect(Bookmark.preview(String(repeating: grapheme, count: 161)) == String(repeating: grapheme, count: 159) + "…")
    }
}
