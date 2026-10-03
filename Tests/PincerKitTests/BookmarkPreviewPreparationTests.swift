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
    @Test(.timeLimit(.minutes(2))) func actualChatItemTogglePreparesLargeMultiblockTextOffMain() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        var item = ChatItem(id: "local", role: .user,
                            blocks: [.text("  Opening line  "), .thinking("Excluded reasoning"),
                                     .text(String(repeating: "\n   Details 👨‍👩‍👧‍👦  ", count: 4_000))])
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

    @Test(.timeLimit(.minutes(2))) func actualChatItemRemovalNeverJoinsOrNormalizesText() async {
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

    @Test(.timeLimit(.minutes(2))) func previewPreservesWhitespaceMultiblockAndUnicodeCharacterSemantics() async {
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

/// Workers announce arrival and suspend until explicitly released. No test relies on sleeps
/// or on the scheduler completing a task within a short wall-clock interval.
private actor BookmarkPreparationGate {
    private var entered = 0
    private var open = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []

    func arriveAndWait(_ id: String) async {
        self.entered += 1
        let ready = self.arrivals.filter { $0.0 <= self.entered }
        self.arrivals.removeAll { $0.0 <= self.entered }
        for waiter in ready { waiter.1.resume() }
        guard !self.open else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || self.open { continuation.resume() }
                else { self.held.append(continuation) }
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
    }

    func waitForEntered(_ count: Int) async {
        guard self.entered < count else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || self.open { continuation.resume() }
                else { self.arrivals.append((count, continuation)) }
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
    }

    func releaseAll() {
        self.open = true
        let held = self.held
        let arrivals = self.arrivals
        self.held = []
        self.arrivals = []
        for waiter in held { waiter.resume() }
        for waiter in arrivals { waiter.1.resume() }
    }
}

extension BookmarkPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func cancellationUnwindsGateAndQueueWaiters() async {
        let absentGate = BookmarkPreparationGate()
        let arrival = Task { await absentGate.waitForEntered(1) }
        arrival.cancel()
        await arrival.value
        await absentGate.releaseAll()

        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        #expect(store.toggle(ChatItem(id: "cancel", role: .assistant, blocks: [.text("Held")]), sessionKey: "main"))
        await gate.waitForEntered(1)
        let drain = Task { await store.waitForPreviewPreparation() }
        drain.cancel()
        await drain.value
        #expect(queue.activeCount == 1)
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(queue.activeCount == 0 && queue.retainedBytes == 0)
    }

    @Test(.timeLimit(.minutes(2))) func pendingRemovalReleasesBytesAndActiveRemovalCannotResurrect() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        let active = ChatItem(id: "active", role: .assistant, blocks: [.text("Active preview")])
        let pending = ChatItem(id: "pending", role: .assistant, blocks: [.text("Pending preview")])
        #expect(store.toggle(active, sessionKey: "main"))
        await gate.waitForEntered(1)
        #expect(store.toggle(pending, sessionKey: "main"))
        #expect(queue.activeCount == 1 && queue.pendingCount == 1)
        let charged = queue.retainedBytes
        #expect(!store.toggle(pending, sessionKey: "main"))
        #expect(queue.pendingCount == 0 && queue.retainedBytes < charged)
        #expect(!store.toggle(active, sessionKey: "main"))
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.isEmpty)
        #expect(queue.activeCount == 0 && queue.pendingCount == 0 && queue.retainedBytes == 0)
    }

    @Test(.timeLimit(.minutes(2))) func retoggleSameIdentityPublishesOnlyTheLatestPreview() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        let old = ChatItem(id: "same", role: .assistant, blocks: [.text("Old text")])
        let new = ChatItem(id: "same", role: .user, blocks: [.text("New text")])
        #expect(store.toggle(old, sessionKey: "main"))
        await gate.waitForEntered(1)
        #expect(!store.toggle(old, sessionKey: "main"))
        #expect(store.toggle(new, sessionKey: "main"))
        #expect(store.bookmarks.first?.role == "user")
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.preview == "New text")
        #expect(store.bookmarks.first?.role == "user")
    }

    @Test(.timeLimit(.minutes(2))) func authoritativeSyncAndConfirmedDeletionInvalidateInFlightPreparation() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        #expect(store.toggle(ChatItem(id: "sync", role: .assistant, blocks: [.text("Stale local text")]), sessionKey: "main"))
        await gate.waitForEntered(1)
        let local = store.bookmarks.first!
        var remote = local
        remote.preview = "Authoritative remote preview"
        let shard = Bookmark.shard(ofKey: local.id)
        store.apply(synced: [remote.id: remote.syncedValue], shard: shard)
        // A second pull with equal values must still leave the worker invalidated.
        store.apply(synced: [remote.id: remote.syncedValue], shard: shard)
        #expect(store.bookmarks.first?.preview == remote.preview)
        #expect(store.toggle(ChatItem(id: "deleted", role: .assistant, blocks: [.text("Deleted preview")]), sessionKey: "deleted-chat"))
        await store.removeConfirmedSessions(["deleted-chat"])
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.map(\.id) == [remote.id])
        #expect(store.bookmarks.first?.preview == remote.preview)
    }

    @Test(.timeLimit(.minutes(2))) func matchingSyncedPlaceholderPreservesPendingLocalPreview() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        #expect(store.toggle(ChatItem(id: "equal", role: .assistant, blocks: [.text("Prepared after self echo")]), sessionKey: "main"))
        await gate.waitForEntered(1)
        let local = store.bookmarks.first!
        #expect(local.preview.isEmpty)
        store.apply(synced: [local.id: local.syncedValue], shard: Bookmark.shard(ofKey: local.id))
        #expect(store.bookmarks.first?.preview == "")
        #expect(store.bookmarks.first?.id == local.id)
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.first?.preview == "Prepared after self echo", "An echo of the current placeholder must preserve its pending preparation despite wire date rounding")
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["different", "same", "owned"])
    func preparedDropNoticeRespectsItsOperationOwnership(_ laterNotice: String) async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Notice test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        let messageID = "notice-message"
        let id = Bookmark.id(sessionKey: "main", messageId: messageID)
        let shard = Bookmark.shard(ofKey: id)
        let fillerID = (0..<1_000).map { "filler-\($0)" }.first {
            Bookmark.shard(ofKey: Bookmark.id(sessionKey: "main", messageId: $0)) == shard
        }!
        let item = ChatItem(id: messageID, role: .assistant, blocks: [.text(String(repeating: "a", count: 200))])
        var filler = Bookmark(sessionKey: "main", messageId: fillerID, preview: "Old bookmark", role: "",
                              createdAt: Date(timeIntervalSince1970: 1))
        let placeholder = Bookmark(sessionKey: "main", messageId: messageID, preview: "",
                                   role: item.role.rawValue, messageDate: item.timestamp)
        // Match the actual star's role/date metadata. ASCII padding grows JSON by exactly
        // one byte per character, leaving 20 bytes for the immediate empty preview.
        let baseSize = BookmarkStore.syncedSize([filler.id: filler.syncedValue, placeholder.id: placeholder.syncedValue])
        let padding = BookmarkStore.syncedByteBudget - 20 - baseSize
        #expect(padding > 0)
        filler.role = String(repeating: "r", count: max(0, padding))
        let initialSize = BookmarkStore.syncedSize([filler.id: filler.syncedValue, placeholder.id: placeholder.syncedValue])
        var prepared = placeholder
        prepared.preview = Bookmark.preview(item.plainText)
        let preparedSize = BookmarkStore.syncedSize([filler.id: filler.syncedValue, prepared.id: prepared.syncedValue])
        #expect(initialSize <= BookmarkStore.syncedByteBudget)
        #expect(preparedSize > BookmarkStore.syncedByteBudget)
        store.add(filler)
        let operation = ChatNoticeOperation(chat)
        let onPrepared: @MainActor @Sendable (Int) -> Void = { dropped in
            #expect(dropped > 0)
            operation.publishIfCurrent("Dropped older bookmark")
        }
        let added = store.toggle(item, sessionKey: "main", messageId: messageID, onPreviewPrepared: onPrepared)
        #expect(added)
        operation.publish("Starred")
        await gate.waitForEntered(1)
        #expect(store.droppedCount == 0)
        if laterNotice == "different" { chat.notice = "Unrelated newer notice" }
        if laterNotice == "same" { chat.notice = "Starred" }
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.droppedCount == 1)
        let expected = laterNotice == "owned" ? "Dropped older bookmark" : laterNotice == "same" ? "Starred" : "Unrelated newer notice"
        #expect(chat.notice == expected)
    }

    @Test(.timeLimit(.minutes(2))) func oneGiantGraphemeCannotPublishAnUnboundedPreview() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        // Combining marks extend the preceding base into one Character. This input is
        // admitted by bytes, yet a 160-Character cap alone would retain every mark.
        let text = "a" + String(repeating: "\u{0301}", count: 20_000)
        #expect(text.count == 1)
        #expect(text.utf8.count < 256 * 1024)
        let item = ChatItem(id: "giant-grapheme", role: .assistant, blocks: [.text(text)])
        let records = BookmarkPreparationRecords(id: Bookmark.id(sessionKey: "main", messageId: item.id))
        store.previewPreparationProbe = { records.record(id: $0, onMain: $1) }
        #expect(store.toggle(item, sessionKey: "main"))
        #expect(store.isBookmarked(sessionKey: "main", messageId: item.id))
        await store.waitForPreviewPreparation()
        #expect(records.snapshot == [false])
        #expect(store.bookmarks.first?.preview == "", "The worker must reject preview output over its byte cap before Main applies or encodes it")
    }

    @Test(.timeLimit(.minutes(2))) func noncontiguousUTF8UsesImmediateEmptyPreviewFallbackWhenAvailable() async {
        // NSString-backed strings are platform dependent. Assert the fallback only if
        // the fixture actually establishes noncontiguous UTF-8 without materializing it.
        let bridged: String = NSString(string: String(repeating: "é", count: 2_000)) as String
        guard !bridged.isContiguousUTF8 else { return }
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        let item = ChatItem(id: "noncontiguous", role: .assistant, blocks: [.text(bridged)])
        #expect(BookmarkPreviewInput.capture(item, sessionKey: "main", messageId: item.id)?.retainedBytes == nil)
        let records = BookmarkPreparationRecords(id: Bookmark.id(sessionKey: "main", messageId: item.id))
        store.previewPreparationProbe = { records.record(id: $0, onMain: $1) }
        #expect(store.toggle(item, sessionKey: "main"))
        #expect(store.isBookmarked(sessionKey: "main", messageId: item.id))
        await store.waitForPreviewPreparation()
        #expect(records.snapshot.isEmpty)
        #expect(store.bookmarks.first?.preview == "")
    }

    @Test(.timeLimit(.minutes(2))) func remoteRemovalCannotBeResurrectedByHeldWorker() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        #expect(store.toggle(ChatItem(id: "removed", role: .assistant, blocks: [.text("Old local preview")]), sessionKey: "main"))
        await gate.waitForEntered(1)
        let id = store.bookmarks.first!.id
        store.apply(synced: [:], shard: Bookmark.shard(ofKey: id))
        #expect(store.bookmarks.isEmpty)
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func admissionAndQueueBudgetsKeepFallbackStarsImmediate() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gate = BookmarkPreparationGate()
        defer { Task { await gate.releaseAll() } }
        let queue = BookmarkPreviewPreparationQueue(beforePrepare: { await gate.arriveAndWait($0) })
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = queue
        #expect(store.toggle(ChatItem(id: "active", role: .assistant, blocks: [.text("Active")]), sessionKey: "main"))
        await gate.waitForEntered(1)
        for number in 0..<40 {
            let item = ChatItem(id: "queued-\(number)", role: .assistant,
                                blocks: [.text(String(repeating: "x", count: 256 * 1024))])
            #expect(store.toggle(item, sessionKey: "main"))
            #expect(store.isBookmarked(sessionKey: "main", messageId: item.id))
            #expect(queue.activeCount <= 1 && queue.pendingCount <= 32)
            #expect(queue.retainedBytes <= 8 * 1024 * 1024)
        }
        let pending = queue.pendingCount
        let charged = queue.retainedBytes
        let oversized = ChatItem(id: "oversized", role: .assistant,
                                 blocks: [.text(String(repeating: "x", count: 256 * 1024 + 1))])
        #expect(store.toggle(oversized, sessionKey: "main"))
        let manyBlocks = ChatItem(id: "many-blocks", role: .assistant, blocks: Array(repeating: .text("x"), count: 65))
        #expect(store.toggle(manyBlocks, sessionKey: "main"))
        #expect(store.bookmarks.first(where: { $0.messageId == oversized.id })?.preview == "")
        #expect(store.bookmarks.first(where: { $0.messageId == manyBlocks.id })?.preview == "")
        #expect(queue.pendingCount == pending && queue.retainedBytes == charged)
        store.removeAll()
        #expect(queue.pendingCount == 0)
        await gate.releaseAll()
        await store.waitForPreviewPreparation()
        #expect(store.bookmarks.isEmpty && queue.retainedBytes == 0)
    }
}
