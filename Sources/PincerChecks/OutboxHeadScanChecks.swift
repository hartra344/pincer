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
    gateway.outbox = Outbox(entries: unrelated + uploads)
    gateway.outboxHeadScanVisits = 0
    gateway.resyncOutboxHolds()

    check(gateway.chat(for: target).items.filter { $0.outboxHold == .expensive }.count == 1,
          "only the actual target-session head is held")
    check(gateway.outboxHeadScanVisits <= (unrelated.count + uploads.count) * 2,
          "one demo hold resync scans linearly (\(gateway.outboxHeadScanVisits) visits)")
}
