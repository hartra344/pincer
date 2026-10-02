import Foundation
@testable import PincerKit

@MainActor
func runDemoOutboxHeadScanChecks() async {
    let (defaults, suite) = scratchDefaults()
    let network = NetworkConditions()
    network.override(expensive: true, constrained: false)
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, network: network)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let connected = await waitFor("demo outbox head scan", timeout: 10) {
        gateway.state.isConnected && gateway.hello != nil
    }
    check(connected, "the demo Gateway supplies connected hold conditions")
    guard connected else { return }
    await gateway.outboxLoadTask?.value

    let target = "agent:main:main"
    _ = gateway.chat(for: target)
    let count = 40
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let unrelated = (0..<count).map { index in
        OutboxEntry(id: "scan-other-\(index)", sessionKey: "agent:scan-other:main",
                    text: "other", createdAt: now)
    }
    let large = OutboxEntry.largeUploadBytes + 1
    let uploads = (0..<count).map { index in
        OutboxEntry(id: "scan-target-\(index)", sessionKey: target, text: "upload", createdAt: now,
                    attachments: [OutboxAttachmentRef(id: UUID(), fileName: "plan-\(index).png",
                                                      mimeType: "image/png", byteCount: large)])
    }
    gateway.outboxHeadScanVisits = 0
    gateway.outbox = Outbox(entries: unrelated + uploads)
    gateway.resyncOutboxHolds()

    check(gateway.chat(for: target).items.filter { $0.outboxHold == .expensive }.count == 1,
          "only the actual target-session head is held")
    check(gateway.outboxHeadScanVisits <= (unrelated.count + uploads.count) * 2,
          "one demo hold resync scans linearly (\(gateway.outboxHeadScanVisits) visits)")

    let blocked = OutboxEntry(id: "scan-failed-head", sessionKey: target, text: "failed",
                              createdAt: now,
                              state: .failed(OutboxFailure(message: "retry", retryable: true)),
                              attachments: [OutboxAttachmentRef(id: UUID(), fileName: "failed.png",
                                                                mimeType: "image/png", byteCount: large)])
    let afterBlocked = uploads[0]
    gateway.outbox = Outbox(entries: [blocked, afterBlocked])
    check(gateway.hold(for: afterBlocked) == nil,
          "a failed session head prevents holding a later upload")
    gateway.updateOutbox { $0.retry(id: blocked.id) }
    let retried = gateway.outbox.entry(id: blocked.id)
    check(retried.flatMap { gateway.hold(for: $0) } == .expensive,
          "retry invalidates the cached blocker and restores the large head")
    gateway.updateOutbox { $0.delete(id: blocked.id) }
    check(gateway.hold(for: afterBlocked) == .expensive,
          "deleting the head invalidates the cache and exposes the large upload")

    let sendNow = OutboxEntry(id: "scan-send-now", sessionKey: target, text: "send now",
                              createdAt: now,
                              attachments: [OutboxAttachmentRef(id: UUID(), fileName: "now.png",
                                                                mimeType: "image/png",
                                                                byteCount: large)],
                              sendOnAnyNetwork: true)
    gateway.outbox = Outbox(entries: [sendNow, afterBlocked])
    check(gateway.hold(for: afterBlocked) == nil,
          "Send Now remains the session head and blocks later uploads")
    gateway.updateOutbox { $0.delete(id: sendNow.id) }
    check(gateway.hold(for: afterBlocked) == .expensive,
          "deleting Send Now releases the next upload after cache invalidation")

    let sending = OutboxEntry(id: "scan-sending-head", sessionKey: target, text: "sending",
                              createdAt: now, state: .sending)
    gateway.outbox = Outbox(entries: [sending, afterBlocked])
    check(gateway.hold(for: afterBlocked) == nil,
          "a sending entry remains the head until the send resolves")
    gateway.updateOutbox { $0.markSent(id: sending.id) }
    check(gateway.hold(for: afterBlocked) == .expensive,
          "resolving a sending head exposes the next upload")

    let memoryOnly = OutboxEntry(id: "scan-memory-head", sessionKey: target, text: "memory",
                                 createdAt: now, hasAttachments: true)
    gateway.outbox = Outbox(entries: [memoryOnly, afterBlocked])
    check(gateway.hold(for: afterBlocked) == nil,
          "a memory-only attachment remains an ordering blocker")
    gateway.updateOutbox { $0.delete(id: memoryOnly.id) }
    check(gateway.hold(for: afterBlocked) == .expensive,
          "deleting a memory-only head exposes the next upload")
}
