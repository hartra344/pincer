#if DEBUG
import Foundation
@testable import PincerKit

/// Kit-level ordinary coverage only: the macOS UI test exercises actual pending ingestion.
@MainActor private func checkQuickCapturePreparedAttachment() async {
    let (defaults, suite) = scratchDefaults()
    GatewayProfileStore.save([.demo()], to: defaults)
    let app = AppModel(defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    guard let gateway = app.gateways.first else {
        check(false, "owned Quick Capture Demo profile exists")
        defaults.removePersistentDomain(forName: suite); return
    }
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("prepared attachment Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "actual Demo bootstrap completed"); guard ready else { return }
    let model = QuickCaptureModel(app: app, defaults: defaults)
    guard let item = model.items.first(where: {
        if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:main" }; return false
    }), model.pick(item) else { check(false, "actual enabled seeded target is selected"); return }
    let data = await Task.detached {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }.value
    let attachment = OutgoingAttachment(fileName: "prepared.png", mimeType: "image/png", data: data)
    model.attachments.append(attachment)
    let text = "prepared-attachment-" + UUID().uuidString
    model.text = text
    check(model.canSend, "actual prepared attachment and text admit Send")
    let accepted = await model.send()
    check(accepted && !model.isSending && model.text.isEmpty && model.attachments.isEmpty,
          "ordinary accepted attachment send completes and clears its captured draft")
    do {
        let history = try await gateway.connection.request("chat.history", ["sessionKey": .string("agent:main:main"), "limit": .number(200)])
        let message = history["messages"]?.array?.first { row in
            row["role"]?.string == "user" && (row["content"]?.array ?? []).contains { $0["text"]?.string == text }
        }
        check(message != nil, "actual Demo history contains the exact sent text")
        check((message?["content"]?.array ?? []).contains { $0["type"]?.string == "image" && $0["alt"]?.string == attachment.fileName },
              "actual Demo records the prepared attachment as an image")
    } catch { check(false, "actual prepared attachment history read completed") }
}

@MainActor func runQuickCapturePreparedAttachmentChecks() async { await checkQuickCapturePreparedAttachment() }
@MainActor func runDemoQuickCapturePreparedAttachmentChecks() async { await checkQuickCapturePreparedAttachment() }
#endif
