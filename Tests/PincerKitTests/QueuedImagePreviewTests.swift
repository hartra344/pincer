import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Queued image preview")
struct QueuedImagePreviewTests {
    let scratch = ScratchDefaults()
    let key = "agent:main:main"

    func restoredRow(state: OutboxState) -> (GatewayStore, ChatStore) {
        let gateway = GatewayStore(profile: GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = nil
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "photo.png", mimeType: "image/png", byteCount: data.count)
        let entry = OutboxEntry(id: "queued-image", sessionKey: key, text: "Look", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                state: state, attachments: [ref])
        gateway.outboxAttachments[entry.id] = [OutgoingAttachment(fileName: ref.fileName, mimeType: ref.mimeType, data: data)]
        let chat = gateway.chat(for: key)
        gateway.outbox = Outbox(entries: [entry])
        chat.syncOutbox([entry])
        return (gateway, chat)
    }

    func hasImage(_ chat: ChatStore) -> Bool {
        chat.items.contains { item in
            item.idempotencyKey == "queued-image" && item.blocks.contains { block in
                if case .image = block { return true }
                return false
            }
        }
    }

    @Test func queuedRestoredImageHasPreview() {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        #expect(hasImage(chat), "a restored queued image must have an image preview instead of only a file chip")
    }

    @Test func failedRestoredImageKeepsPreview() {
        let (gateway, chat) = restoredRow(state: .failed(OutboxFailure(message: "Try again", retryable: true)))
        defer { gateway.stop(); scratch.remove() }
        #expect(hasImage(chat), "failed attachment rows still need an image preview")
    }
}
