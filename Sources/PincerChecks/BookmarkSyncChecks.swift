import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

#if DEBUG
/// An exact-ID probe with a fixed record cap; unrelated gateway activity cannot affect it.
private final class BookmarkSyncPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let id: String
    private var records: [Bool] = []
    init(id: String) { self.id = id }
    func record(_ id: String, _ onMain: Bool) {
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
    let noticeChat = ChatStore(sessionKey: DemoBookmarks.tripSessionKey, agentId: "main", gateway: gateway, headless: true)
    let ownedNotice = ChatNoticeOperation(noticeChat)
    ownedNotice.publish("Bookmark saved")
    check(ownedNotice.publishIfCurrent("Older bookmark dropped") && noticeChat.notice == "Older bookmark dropped",
          "bookmark demo: an owning operation can publish its completed notice")
    let differentNotice = ChatNoticeOperation(noticeChat)
    differentNotice.publish("Bookmark saved")
    noticeChat.notice = "A newer unrelated notice"
    check(!differentNotice.publishIfCurrent("Stale bookmark completion") && noticeChat.notice == "A newer unrelated notice",
          "bookmark demo: a newer notice prevents a stale bookmark completion from replacing it")
    let repeatedNotice = ChatNoticeOperation(noticeChat)
    repeatedNotice.publish("Bookmark saved")
    noticeChat.notice = "Bookmark saved"
    check(!repeatedNotice.publishIfCurrent("Stale bookmark completion") && noticeChat.notice == "Bookmark saved",
          "bookmark demo: assigning the same notice text again still transfers ownership")
    // Exercise the same ChatItem entry point as the transcript's star action, with large
    // multiblock text; the existing seeded demo bookmarks remain the round-trip controls.
    var message = ChatItem(id: "sync-check-local", role: .assistant,
                           blocks: [.text("Synced through users.prefs"),
                                    .text(String(repeating: "\n  Detailed trip planning 👨‍👩‍👧‍👦  ", count: 4_000))])
    message.transcriptId = "sync-check-1"
    message.timestamp = Date(timeIntervalSince1970: 123)
    let messageID = Bookmark.id(sessionKey: DemoBookmarks.tripSessionKey, messageId: "sync-check-1")
    let probe = BookmarkSyncPreparationProbe(id: messageID)
    store.previewPreparationProbe = { probe.record($0, $1) }
    defer { store.previewPreparationProbe = nil }
    check(store.toggle(message, sessionKey: DemoBookmarks.tripSessionKey), "bookmark demo: actual ChatItem toggle stars immediately")
    check(store.isBookmarked(sessionKey: DemoBookmarks.tripSessionKey, messageId: "sync-check-1"),
          "bookmark demo: transcript identity is available before preview completion")
    await store.waitForPreviewPreparation()
    check(probe.snapshot == [false], "bookmark demo: actual large text joining and preview preparation run off-main")
    guard let item = store.bookmarks.first(where: { $0.id == messageID }) else {
        check(false, "bookmark demo: prepared bookmark is retained")
        return
    }
    check(item.preview == Bookmark.preview(message.plainText) && item.role == "assistant" && item.messageDate == message.timestamp,
          "bookmark demo: large multiblock preview preserves text, role and timestamp")
    let shard = Bookmark.shard(ofKey: item.id)
    var written = false
    for _ in 0..<50 where !written {
        written = await stored(shard)[item.id] == item.syncedValue
        if !written { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(written, "bookmark demo: the bookmark is written to pincer.bookmarks.\(shard) by users.prefs.set")
    let demoValue = await stored(shard)[item.id].flatMap { Bookmark(syncedKey: item.id, value: $0) }
    check(demoValue?.id == item.id && demoValue?.role == item.role && demoValue?.preview == Bookmark(syncedKey: item.id, value: item.syncedValue)?.preview, "bookmark demo: the stored value decodes back to the bookmark")
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
    check(!store.toggle(message, sessionKey: DemoBookmarks.tripSessionKey), "bookmark demo: actual ChatItem toggle again un-stars it")
    await store.waitForPreviewPreparation()
    check(probe.snapshot == [false], "bookmark demo: un-starring does not prepare text again")
    var deleted = false
    for _ in 0..<50 where !deleted {
        deleted = await stored(shard)[item.id] == nil
        if !deleted { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(deleted, "bookmark demo: un-starring deletes the entry from users.prefs")
    // A real, confirmed delete clears the local stars and their synced entries; other chats keep theirs.
    let deletionBookmark = Bookmark(sessionKey: DemoBookmarks.tripSessionKey, messageId: "delete-sync-check",
                                    preview: "A saved trip message to delete")
    store.add(deletionBookmark)
    var deletionSeedWritten = false
    let seedDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !deletionSeedWritten && ContinuousClock.now < seedDeadline {
        deletionSeedWritten = await stored(Bookmark.shard(ofKey: deletionBookmark.id))[deletionBookmark.id] != nil
        if !deletionSeedWritten { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(deletionSeedWritten, "bookmark demo: the deletion fixture is saved to users.prefs before deleting the chat")
    let tripBookmarks = store.bookmarks(in: DemoBookmarks.tripSessionKey)
    check(!tripBookmarks.isEmpty, "bookmark demo: deleted-chat scenario starts with a saved trip message")
    await gateway.sessionManager.load(filter: .all)
    let outcome = await gateway.sessionManager.delete([DemoBookmarks.tripSessionKey])
    check(outcome.succeeded == [DemoBookmarks.tripSessionKey] && outcome.failed.isEmpty,
          "bookmark demo: the Gateway confirms deletion of the trip chat")
    check(store.bookmarks(in: DemoBookmarks.tripSessionKey).isEmpty && !store.bookmarks.isEmpty,
          "bookmark demo: only the deleted chat's bookmarks are removed locally")
    var removedRemotely = false
    let deletionDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !removedRemotely && ContinuousClock.now < deletionDeadline {
        removedRemotely = true
        for bookmark in tripBookmarks {
            if await stored(Bookmark.shard(ofKey: bookmark.id))[bookmark.id] != nil { removedRemotely = false }
        }
        if !removedRemotely { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(removedRemotely, "bookmark demo: confirmed deletion removes the saved messages from users.prefs")
    #else
    print("  skipped: needs @testable access to PincerKit (debug builds)")
    #endif
}
