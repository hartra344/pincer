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
        store.outbox = Outbox(entries: unrelated + uploads)
        store.outboxHeadScanVisits = 0

        store.resyncOutboxHolds()

        #expect(store.chat(for: target).items.filter { $0.outboxHold == .expensive }.count == 1,
                "only the visible large-upload head is held")
        #expect(store.outboxHeadScanVisits <= (unrelated.count + uploads.count) * 2,
                "one resync should scan queue heads linearly; visited \(store.outboxHeadScanVisits) entries")
    }
}
