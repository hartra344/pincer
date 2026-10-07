#if os(macOS) && DEBUG
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct QuickCaptureAttachmentPreparationTests {
    actor Gate {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !(await condition()) {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func actualIngestionBlocksSendAndKeepsPreparedImageIntent() async throws {
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: UIFixtures.identity())
        let gateway = try #require(app.gateways.first)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        try await wait { gateway.state.isConnected && gateway.bootstrapped }
        let model = QuickCaptureModel(app: app, defaults: scratch.defaults)
        let item = try #require(model.items.first { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:main" }; return false })
        try #require(model.pick(item))
        model.text = "quick-image-" + UUID().uuidString
        try #require(model.canSend && !model.isSending)
        let queue = BoundedPreparationQueue<AttachmentIngestResult>()
        let preparation = Gate(), acknowledgement = Gate()
        var fixtureWorkCompleted = false
        var sending: Task<Bool, Never>?
        do {
            queue.submit(operation: { await preparation.hold(); return .failure("owned fixture gate") }, completion: { _ in fixtureWorkCompleted = true })
            try await wait { await preparation.entered }
            let png = await Task.detached {
                Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            }.value
            var report: String?
            let ingestion = QuickCaptureAttachmentIngest.make(model: model, imageQueue: queue, report: { report = $0 })
            ingestion.ingest([.data(png, type: .png, name: "owned.png")])
            try #require(queue.pendingCount == 1)
            let admittedWhilePreparing = model.canSend
            #expect(!admittedWhilePreparing, "Actual Quick Capture pending ingestion must block Send admission")
            await gateway.connection.setDemoResponseDelivery { method in
                if method == "chat.send" { await acknowledgement.hold() }
            }
            if admittedWhilePreparing {
                sending = Task { await model.send() }
                try await wait { await acknowledgement.entered }
            }
            await preparation.release()
            try await wait { fixtureWorkCompleted && queue.activeCount == 0 && model.attachments.count == 1 }
            let prepared = try #require(model.attachments.first)
            #expect(prepared.fileName == "owned.png" && report == nil)
            if let sending {
                await acknowledgement.release()
                let accepted = await sending.value
                #expect(accepted)
                #expect(model.attachments == [prepared], "An older send must not erase a subsequently prepared image")
                // Restore only after the strict loss verdict, to exercise ordinary prepared-image send.
                model.attachments = [prepared]
                try #require(model.pick(item))
                model.text = "prepared-image-" + UUID().uuidString
            }
            await gateway.connection.setDemoResponseDelivery(nil)
            try #require(model.canSend)
            let sentText = model.text
            let accepted = await model.send()
            #expect(accepted && model.attachments.isEmpty && model.text.isEmpty)
            let history = try await gateway.connection.request("chat.history", ["sessionKey": .string("agent:main:main"), "limit": .number(200)])
            let message = history["messages"]?.array?.first { row in
                row["role"]?.string == "user" && (row["content"]?.array ?? []).contains { $0["text"]?.string == sentText }
            }
            #expect(message != nil && (message?["content"]?.array ?? []).contains { $0["type"]?.string == "image" && $0["alt"]?.string == prepared.fileName }, "Actual Demo history records the prepared image on the ordinary send")
        } catch {
            sending?.cancel(); await acknowledgement.release(); await preparation.release()
            if let sending { _ = await sending.value }
            // An unstructured cleanup waiter is not already canceled with the enclosing test.
            let draining = Task { @MainActor in try? await wait { queue.activeCount == 0 && queue.pendingCount == 0 } }
            await draining.value
            await gateway.connection.setDemoResponseDelivery(nil)
            throw error
        }
        await gateway.connection.setDemoResponseDelivery(nil)
    }
}
#endif
