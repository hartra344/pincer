import Foundation
import PincerKit

/// Removing one chat from the cache and the index, and recovering an index deleted while open.
/// Runs inside a scratch cache (`withScratchCache`).
@MainActor
func checkMessageIndexRemoval(root: URL?) async {
    let gatewayId = UUID()
    let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("m1", .user, "Removed marmot here", at: 1)], complete: true),
                               gatewayId: gatewayId, sessionKey: "gone", root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("m2", .user, "Kept marmot there", at: 2)], complete: true),
                               gatewayId: gatewayId, sessionKey: "kept", root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("m3", .user, "Direct mongoose", at: 3)], complete: true),
                               gatewayId: gatewayId, sessionKey: "direct", root: root)
    let goneFile = TranscriptCache.file(gatewayId: gatewayId, sessionKey: "gone", root: root)
    await checkAsync({ await allTrue(index.isIndexed(sessionKey: "gone"), index.isIndexed(sessionKey: "kept"),
                                     indexHits(gatewayId, "marmot", root: root).count == 2, fileExists(goneFile),
                                     fileExists(goneFile?.appendingPathExtension("meta"))) },
                     "remove: both chats cached and indexed first")

    await TranscriptCache.remove(gatewayId: gatewayId, sessionKey: "gone", root: root)
    let loaded = await TranscriptCache.load(gatewayId: gatewayId, sessionKey: "gone", root: root)
    let kept = await TranscriptCache.load(gatewayId: gatewayId, sessionKey: "kept", root: root)
    check(!fileExists(goneFile) && !fileExists(goneFile?.appendingPathExtension("meta")) && loaded == nil && kept?.items.count == 1,
          "TranscriptCache.remove deletes the transcript and sidecar, other chats stay")
    await checkAsync({ await allTrue(!index.isIndexed(sessionKey: "gone"), index.isIndexed(sessionKey: "kept"),
                                     indexHits(gatewayId, "marmot", root: root).map(\.sessionKey) == ["kept"]) },
                     "TranscriptCache.remove drops the chat from the index, others still found")
    await index.reconcile(sessionKeys: ["gone", "kept"])
    await checkAsync({ await (indexHits(gatewayId, "marmot", root: root).map(\.sessionKey) == ["kept"]) }, "reconcile doesn't bring a removed chat back")

    await index.remove(sessionKey: "direct")
    await checkAsync({ await allTrue(!index.isIndexed(sessionKey: "direct"), index.chatInfo(sessionKey: "direct") == nil,
                                     indexHits(gatewayId, "mongoose", root: root).isEmpty, indexHits(gatewayId, "marmot", root: root).count == 1) },
                     "MessageIndex.remove drops the chat's rows, others still found")
    let url = MessageIndex.url(gatewayId: gatewayId, root: root)
    check(sqliteInts(url, "SELECT count(*) FROM docs WHERE session_key IN ('gone', 'direct')") == [0]
          && sqliteInts(url, "SELECT count(*) FROM chats WHERE session_key IN ('gone', 'direct')") == [0]
          && sqliteInts(url, "SELECT count(*) FROM messages WHERE messages MATCH 'mongoose'") == [0],
          "no docs, chats or FTS rows are left for removed chats")
    check(sqliteExec(url!, "INSERT INTO messages(messages) VALUES('integrity-check')"), "FTS integrity-check passes after removals")
    await index.remove(sessionKey: "never-indexed")
    await checkAsync({ await (indexHits(gatewayId, "marmot", root: root).count == 1) }, "removing a chat that was never indexed is harmless")
    await TranscriptCache.remove(gatewayId: gatewayId, sessionKey: "never-cached", root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("m4", .user, "Marmot is back", at: 4)], complete: true),
                               gatewayId: gatewayId, sessionKey: "gone", root: root)
    await checkAsync({ await allTrue(index.isIndexed(sessionKey: "gone"), indexHits(gatewayId, "marmot", root: root).count == 2) },
                     "a removed chat saved again is indexed again")

    // Deleted from under an open connection (the system purged the caches folder): the index
    // notices, starts over, and reconcile refills it from the transcripts.
    let vanishing = UUID()
    let vanishingIndex = MessageIndex.shared(gatewayId: vanishing, root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("v1", .user, "Vanishing vicuna", at: 5)], complete: true),
                               gatewayId: vanishing, sessionKey: "v1", root: root)
    await checkAsync({ await (indexHits(vanishing, "vicuna", root: root).count == 1) }, "vanishing: indexed while open")
    if let vanishingURL = MessageIndex.url(gatewayId: vanishing, root: root) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: vanishingURL.path(percentEncoded: false) + suffix))
        }
    }
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("v2", .user, "Returning vicuna", at: 6)], complete: true),
                               gatewayId: vanishing, sessionKey: "v2", root: root)
    _ = try? await vanishingIndex.search("vicuna")
    await vanishingIndex.reconcile(sessionKeys: ["v1", "v2"])
    await checkAsync({ await allTrue(indexHits(vanishing, "vicuna", root: root).count == 2, vanishingIndex.isIndexed(sessionKey: "v1"),
                                     vanishingIndex.isIndexed(sessionKey: "v2"), fileExists(MessageIndex.url(gatewayId: vanishing, root: root))) },
                     "an index deleted while open is rebuilt, and reconcile refills it")
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("v3", .user, "Third vicuna", at: 7)], complete: true),
                               gatewayId: vanishing, sessionKey: "v3", root: root)
    await checkAsync({ await (indexHits(vanishing, "vicuna", root: root).count == 3) }, "saves after the rebuild are indexed")
    TranscriptCache.removeAll(gatewayId: vanishing, root: root)
    TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
}

/// The same removal with the cache off and the index kept in memory (the demo).
@MainActor
func checkMessageIndexRemovalInMemory(gatewayId: UUID, root: URL?) async {
    let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("d1", .user, "Demo dingo one", at: 1)], complete: true),
                               gatewayId: gatewayId, sessionKey: "a", root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("d2", .user, "Demo dingo two", at: 2)], complete: true),
                               gatewayId: gatewayId, sessionKey: "b", root: root)
    await checkAsync({ await (indexHits(gatewayId, "dingo", root: root).count == 2) }, "in memory: both chats indexed")
    await TranscriptCache.remove(gatewayId: gatewayId, sessionKey: "a", root: root)
    await checkAsync({ await allTrue(!index.isIndexed(sessionKey: "a"), index.isIndexed(sessionKey: "b"),
                                     indexHits(gatewayId, "dingo", root: root).map(\.sessionKey) == ["b"]) },
                     "in memory: TranscriptCache.remove drops the chat from the index")
}
