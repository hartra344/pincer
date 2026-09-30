import Foundation
import Testing
@testable import PincerKit

/// A Gateway's cache being deleted while another Gateway under the same root is saved (#458): the
/// other's index is handed out live, so its save is indexed and found. (The hold-back used to be
/// per root, which left such a save on disk but never indexed: 0 hits, ready.)
@Suite("Search index during another Gateway's deletion")
struct SearchIndexClearRaceTests {
    @Test func saveForAnotherGatewayDuringRemoveAllIsIndexed() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let deleted = UUID(), other = UUID()
        // The save's transcript is written; only its index handout falls in the deletion window.
        let url = try #require(TranscriptCache.file(gatewayId: other, sessionKey: "after", root: temp.url))
        let written = TranscriptCache.Snapshot(items: [MessageIndexFileTests.message("z", "zebra after clear", at: 1)], complete: true)
        _ = await TranscriptCache.Writer.shared.write(written, to: url)
        var during: MessageIndex?
        MessageIndex.whileDeleting(root: temp.url, gatewayId: deleted) {
            during = MessageIndex.shared(gatewayId: other, root: temp.url)
        }
        let index = try #require(during)
        await index.index(sessionKey: "after", snapshot: written, fileMtime: Date())
        let found = try await index.search("zebra")
        let indexed = await index.isIndexed(sessionKey: "after")
        #expect(found.count == 1, "\(found.count) hits, indexed: \(indexed)")
        #expect(MessageIndex.shared(gatewayId: other, root: temp.url) === index, "and it's the registered one")
        TranscriptCache.removeAll(gatewayId: other, root: temp.url)
    }

    @Test func aGatewaysOwnIndexIsStillHeldBackWhileItsFolderIsDeleted() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        var during: MessageIndex?
        MessageIndex.whileDeleting(root: temp.url, gatewayId: gateway) {
            during = MessageIndex.shared(gatewayId: gateway, root: temp.url)
        }
        let index = try #require(during)
        await index.index(sessionKey: "k", snapshot: MessageIndexFileTests.snapshot("z", "zebra"), fileMtime: Date())
        #expect(try await index.search("zebra").isEmpty)
        #expect(MessageIndex.shared(gatewayId: gateway, root: temp.url) !== index)
    }

    @Test func aRootWideClearHoldsBackEveryIndexUnderIt() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        var during: MessageIndex?
        MessageIndex.whileDeleting(root: temp.url) { during = MessageIndex.shared(gatewayId: UUID(), root: temp.url) }
        let index = try #require(during)
        await index.index(sessionKey: "k", snapshot: MessageIndexFileTests.snapshot("z", "zebra"), fileMtime: Date())
        #expect(try await index.search("zebra").isEmpty)
    }
}
