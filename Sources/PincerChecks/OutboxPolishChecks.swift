import Foundation
import UniformTypeIdentifiers
@testable import PincerKit

@MainActor
func runShareSavedUploadPolicyChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let tight = GatewayProfile(name: "Small upload limit", url: "ws://127.0.0.1:9", authMode: .none)
    let roomy = GatewayProfile(name: "Roomy upload limit", url: "ws://127.0.0.1:10", authMode: .none)
    let policy = UploadPolicy(maxAttachmentBytes: 100)
    defaults.set(try? JSONEncoder().encode(policy), forKey: GatewayStore.uploadPolicyKey(tight.id))
    let model = ShareModel(profiles: [tight, roomy], identity: nil, defaults: defaults)
    model.setContent(SharedContent(files: [
        SharedFile(name: "report.pdf", typeIdentifier: UTType.pdf.identifier, data: Data(count: 1_000)),
    ]))
    let prepared = await waitFor("saved Share upload limit") { !model.isPreparingAttachments }
    check(prepared && model.attachments.isEmpty && model.attachmentProblems.count == 1,
          "sharing uses the selected Gateway's saved size limit before connecting")
    check(model.attachmentProblems.first?.contains("last known limit") == true,
          "the saved Share upload limit is explicitly labeled last known")
    model.profileId = roomy.id
    check(model.attachmentProblems.isEmpty && model.attachments.isEmpty,
          "switching Gateway immediately clears the previous prepared result")
    let changed = await waitFor("new Share Gateway upload limit") { !model.isPreparingAttachments }
    check(changed && model.attachments.map(\.fileName) == ["report.pdf"] && model.attachmentProblems.isEmpty,
          "another Gateway uses its own limits rather than inheriting the previous one")
}

@MainActor
func runDemoShareUploadPolicyLifecycleChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile.demo()
    defaults.set(try? JSONEncoder().encode(UploadPolicy(maxAttachmentBytes: 100)),
                 forKey: GatewayStore.uploadPolicyKey(profile.id))
    let model = ShareModel(profiles: [profile], identity: DeviceIdentity.loadOrCreate(), defaults: defaults)
    model.setContent(SharedContent(files: [
        SharedFile(name: "notes.txt", typeIdentifier: UTType.plainText.identifier, data: Data(count: 1_000)),
    ]))
    let before = await waitFor("Share saved limit before demo hello") { !model.isPreparingAttachments }
    check(before && model.attachments.isEmpty, "the saved tight limit applies before the live hello")
    model.connect()
    let connected = await waitFor("Share live demo upload limit") { model.phase == .ready && !model.isPreparingAttachments }
    check(connected && model.attachments.map(\.fileName) == ["notes.txt"] && model.attachmentProblems.isEmpty,
          "the live hello replaces the older saved upload limit")
    model.disconnect()
    let offline = await waitFor("Share latest observed policy") { !model.isPreparingAttachments }
    check(offline && model.attachments.map(\.fileName) == ["notes.txt"] && model.attachmentProblems.isEmpty,
          "disconnect retains this Gateway's most recently observed policy")
}

@MainActor
func runDemoOutboxImagePreviewChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let connected = await waitFor("demo queued image connection") { gateway.state.isConnected && gateway.hello != nil }
    check(connected, "the demo outbox connects")
    guard connected else { return }
    await gateway.outboxLoadTask?.value
    let chat = gateway.chat(for: DemoOutbox.sessionKey)
    await chat.load()
    func row() -> ChatItem? { chat.items.first { $0.idempotencyKey == DemoOutbox.queuedAttachmentId } }
    func image() -> ImageRef? {
        row()?.blocks.compactMap { block -> ImageRef? in
            if case let .image(ref) = block { return ref }
            return nil
        }.first
    }
    let preview = await waitFor("demo seating-plan preview") { image() != nil }
    check(preview && image()?.alt == "seating-plan.png", "the seeded queued seating plan has an image preview")
    let encodedBytes = chat.items.filter { $0.outboxState != nil }.flatMap(\.blocks).reduce(0) { sum, block in
        if case let .image(ref) = block { return sum + (ref.base64?.utf8.count ?? 0) }
        return sum
    }
    check(encodedBytes > 0 && encodedBytes <= 1_048_576,
          "queued preview bytes retained by transcript rows stay within 1 MiB (\(encodedBytes))")
    gateway.updateOutbox { $0.markFailed(id: DemoOutbox.queuedAttachmentId, kind: .transient) }
    let failed = await waitFor("failed seating-plan preview") {
        guard let state = row()?.outboxState, case .failed = state else { return false }
        return image() != nil
    }
    check(failed, "a failed queued image retains its preview")
    gateway.updateOutbox { $0.delete(id: DemoOutbox.queuedAttachmentId) }
    check(row() == nil, "deleting the queued image removes its preview row")

    let sentChat = gateway.chat(for: "agent:main:main")
    await sentChat.load()
    let message = "Preview commit regression #557"
    let outcome = await sentChat.sendMessage(message, attachments: [DemoGateway.seatingPlan])
    let accepted = if case .sent = outcome { true } else { false }
    check(accepted, "the demo accepts an image through the normal operator chat.send path")
    let committed = await waitFor("demo image transcript commit") {
        sentChat.items.contains { item in
            item.role == .user && !item.isPending && item.plainText.contains(message)
                && item.blocks.contains { if case .image = $0 { true } else { false } }
        }
    }
    check(committed, "the accepted image is replaced by its committed transcript image")
    check(sentChat.outboxImagePreviews.retainedBytes == 0,
          "committing the image releases the client outbox preview source")
}
