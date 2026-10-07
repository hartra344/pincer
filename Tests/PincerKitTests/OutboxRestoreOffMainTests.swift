import Foundation
import Testing
@testable import PincerKit

/// #915: restoring the saved outbox checks its attachment files off the main thread, and still
/// fails a message whose files are gone while keeping one whose files are there.
@MainActor
@Suite("Outbox restore checks attachments off-main (#915)")
struct OutboxRestoreOffMainTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()

    @Test func restoreChecksAttachmentFilesOffTheMainThread() async throws {
        defer {
            self.temp.remove()
            self.scratch.remove()
        }
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
        let root = self.temp.url
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let bytes = OutgoingAttachment(fileName: "kept.png", mimeType: "image/png", data: Data(repeating: 7, count: 64))
        let kept = OutboxEntry(id: "kept", sessionKey: "agent:main:main", text: "kept",
                               createdAt: created, attachments: OutboxAttachmentStore.refs(for: [bytes]))
        let gone = OutboxEntry(id: "gone", sessionKey: "agent:main:main", text: "gone", createdAt: created,
                               attachments: [OutboxAttachmentRef(id: UUID(), fileName: "gone.png", mimeType: "image/png", byteCount: 64)])
        #expect(OutboxAttachmentStore.enqueueWrite([bytes], entryId: kept.id, gatewayId: profile.id, root: root))
        await OutboxStore.save(Outbox(entries: [kept, gone]), gatewayId: profile.id, root: root)

        let store = GatewayStore(profile: profile, defaults: self.scratch.defaults)
        store.cacheRoot = nil
        store.notifier = nil
        store.outboxRoot = root
        await store.loadOutbox()

        #expect(!OutboxAttachmentStore.mainThreadFileWork.withLock { $0.contains(profile.id) },
                "no attachment file work ran on the main thread while restoring")
        #expect(store.outbox.entries.map(\.id) == ["kept", "gone"], "both restored messages show")
        #expect(store.outbox.entry(id: "kept")?.state == .queued, "a message whose files are there stays queued")
        guard case let .failed(failure)? = store.outbox.entry(id: "gone")?.state else {
            Issue.record("a message whose files are gone fails")
            return
        }
        #expect(!failure.retryable && failure.message.contains("no longer available"))
        #expect(!store.outboxValidating, "sending is no longer held once the check finishes")
    }
}
