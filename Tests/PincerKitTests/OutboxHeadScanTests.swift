import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Outbox head scan cost")
struct OutboxHeadScanTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()

    func finish(_ store: GatewayStore) {
        store.stop()
        self.temp.remove()
        self.scratch.remove()
    }

    @Test func resyncScansHeadsLinearlyAcrossLargeQueues() async throws {
        let network = NetworkConditions()
        network.override(expensive: true, constrained: false)
        let store = GatewayStore(profile: .demo(), defaults: self.scratch.defaults,
                                 identity: Fixtures.identity(), network: network)
        store.outboxRoot = self.temp.url
        store.start()
        defer { self.finish(store) }
        let connected = await eventually(timeout: .seconds(10)) { store.state.isConnected && store.hello != nil }
        #expect(connected, "demo Gateway is connected with upload limits")
        guard connected else { return }
        await store.outboxLoadTask?.value

        let target = "agent:head-scan:main"
        _ = store.chat(for: target)
        let count = 80
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let unrelated = (0..<count).map { index in
            OutboxEntry(id: "unrelated-\(index)", sessionKey: "agent:head-scan:other",
                        text: "unrelated", createdAt: createdAt)
        }
        let large = OutboxEntry.largeUploadBytes + 1
        let uploads = (0..<count).map { index in
            let attachment = OutboxAttachmentRef(id: UUID(), fileName: "large-\(index).png",
                                                 mimeType: "image/png", byteCount: large)
            return OutboxEntry(id: "target-\(index)", sessionKey: target, text: "upload",
                               createdAt: createdAt, attachments: [attachment])
        }
        store.outboxHeadScanVisits = 0
        store.outbox = Outbox(entries: unrelated + uploads)

        store.resyncOutboxHolds()

        #expect(store.chat(for: target).items.filter { $0.outboxHold == .expensive }.count == 1,
                "only the visible large-upload head is held")
        #expect(store.outboxHeadScanVisits <= (unrelated.count + uploads.count) * 2,
                "one resync should scan queue heads linearly; visited \(store.outboxHeadScanVisits) entries")
    }

    @Test func headCacheInvalidatesForRetryDeleteAndSendNow() async throws {
        let network = NetworkConditions()
        network.override(expensive: true, constrained: false)
        let store = GatewayStore(profile: .demo(), defaults: self.scratch.defaults,
                                 identity: Fixtures.identity(), network: network)
        store.start()
        defer { self.finish(store) }
        let connected = await eventually(timeout: .seconds(10)) { store.state.isConnected && store.hello != nil }
        #expect(connected, "demo Gateway is connected with upload limits")
        guard connected else { return }
        await store.outboxLoadTask?.value

        let key = "agent:head-cache:main"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func large(_ id: String, state: OutboxState = .queued, memoryOnly: Bool = false) -> OutboxEntry {
            let refs = memoryOnly ? [] : [OutboxAttachmentRef(id: UUID(), fileName: "\(id).png",
                                                               mimeType: "image/png",
                                                               byteCount: OutboxEntry.largeUploadBytes + 1)]
            return OutboxEntry(id: id, sessionKey: key, text: id, createdAt: now,
                               state: state, hasAttachments: memoryOnly, attachments: refs)
        }

        let failed = large("failed", state: .failed(OutboxFailure(message: "retry", retryable: true)))
        let afterFailed = large("after-failed")
        store.outbox = Outbox(entries: [failed, afterFailed])
        #expect(store.hold(for: afterFailed) == nil, "failed heads block later upload eligibility")
        store.updateOutbox { $0.retry(id: failed.id) }
        let retried = store.outbox.entry(id: failed.id)
        #expect(retried.flatMap { store.hold(for: $0) } == .expensive,
                "retry invalidates the cached blocker and restores its current entry")

        let sending = large("sending", state: .sending)
        let afterSending = large("after-sending")
        store.outbox = Outbox(entries: [sending, afterSending])
        #expect(store.hold(for: afterSending) == nil, "sending heads block later uploads")
        store.updateOutbox { $0.markSent(id: sending.id) }
        #expect(store.hold(for: afterSending) == .expensive, "removing a sent head exposes the next upload")

        let memoryOnly = large("memory-only", memoryOnly: true)
        let afterMemory = large("after-memory")
        store.outbox = Outbox(entries: [memoryOnly, afterMemory])
        #expect(store.hold(for: afterMemory) == nil, "memory-only heads retain their ordering block")
        store.updateOutbox { $0.delete(id: memoryOnly.id) }
        #expect(store.hold(for: afterMemory) == .expensive, "deleting a memory-only head exposes the next upload")

        let sendNow = large("send-now")
        let afterSendNow = large("after-send-now")
        store.outbox = Outbox(entries: [sendNow, afterSendNow])
        store.updateOutbox { $0.allowAnyNetwork(id: sendNow.id) }
        #expect(store.hold(for: afterSendNow) == nil, "Send Now releases only the head's network hold, not its queue position")
        store.updateOutbox { $0.delete(id: sendNow.id) }
        #expect(store.hold(for: afterSendNow) == .expensive, "deleting a Send Now head exposes the next upload")
    }

    @Test func headCachesAreIsolatedPerGateway() async throws {
        let firstNetwork = NetworkConditions()
        firstNetwork.override(expensive: true, constrained: false)
        let secondNetwork = NetworkConditions()
        secondNetwork.override(expensive: true, constrained: false)
        let first = GatewayStore(profile: .demo(), defaults: self.scratch.defaults,
                                 identity: Fixtures.identity(), network: firstNetwork)
        let secondScratch = ScratchDefaults()
        let second = GatewayStore(profile: .demo(), defaults: secondScratch.defaults,
                                  identity: Fixtures.identity(), network: secondNetwork)
        first.start()
        second.start()
        defer {
            self.finish(first)
            second.stop()
            secondScratch.remove()
        }
        let ready = await eventually(timeout: .seconds(10)) {
            first.state.isConnected && first.hello != nil && second.state.isConnected && second.hello != nil
        }
        #expect(ready, "both demo Gateways connect independently")
        guard ready else { return }
        await first.outboxLoadTask?.value
        await second.outboxLoadTask?.value

        let key = "agent:isolated-head-cache:main"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let readyHead = OutboxEntry(id: "ready-head", sessionKey: key, text: "upload", createdAt: now,
                                    attachments: [OutboxAttachmentRef(id: UUID(), fileName: "ready.png",
                                                                      mimeType: "image/png",
                                                                      byteCount: OutboxEntry.largeUploadBytes + 1)])
        let blockedHead = OutboxEntry(id: "blocked-head", sessionKey: key, text: "blocked", createdAt: now,
                                      state: .failed(OutboxFailure(message: "retry", retryable: true)))
        let laterUpload = OutboxEntry(id: readyHead.id, sessionKey: key, text: "upload", createdAt: now,
                                      attachments: readyHead.attachments)
        first.outbox = Outbox(entries: [readyHead])
        second.outbox = Outbox(entries: [blockedHead, laterUpload])

        #expect(first.hold(for: readyHead) == .expensive)
        #expect(second.hold(for: laterUpload) == nil,
                 "one Gateway's eligible-head cache cannot leak into another Gateway")
    }
}
