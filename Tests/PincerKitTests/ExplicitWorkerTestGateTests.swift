#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ExplicitWorkerTestGateTests {
    @Test func openBeforeWorkerInstallsItsContinuationStillCompletes() async {
        let gate = ExplicitWorkerTestGate()
        gate.open()
        let worker = Task.detached { await gate.hold() }
        await worker.value
        #expect(await gate.waitUntilEntered())
    }

    @Test @MainActor func cancellingHeldActualWorkerDoesNotReleaseItsLease() async throws {
        let gate = ExplicitWorkerTestGate()
        let cache = MessagePartExcerptCache()
        cache.preparationHoldForTesting = { await gate.hold() }
        let source = MessagePartExcerptSource("Held excerpt.")
        _ = cache.excerpt(for: source)
        let worker = cache.activeTaskForTesting
        do {
            try #require(await gate.waitUntilEntered())
            let actual = try #require(worker)
            actual.cancel()
            // Progress on a separate continuation must not release the cancelled held operation.
            await Task.detached(priority: .userInitiated) {}.value
            #expect(cache.activeCount == 1 && cache.cachedCount == 0)
            gate.open()
            await actual.value
            #expect(cache.activeCount == 0 && cache.inFlightKeyCount == 0)
            #expect(cache.excerpt(for: source) == "Held excerpt.")
        } catch {
            gate.open()
            await worker?.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func sharedOutboxLeaseSerializesMemoryAndPersistedCallsUntilExplicitOpen(cancelFirst: Bool) async throws {
        let gate = ExplicitWorkerTestGate()
        let worker = OutboxImagePreviewWorker()
        let attachment = OutgoingAttachment(fileName: "pixel.png", mimeType: "image/png",
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!)
        let first = Task { await worker.prepare(attachment, probe: { await gate.hold() }) }
        var second: Task<(image: ImageRef, encodedBytes: Int)?, Never>?
        var persisted: Task<(image: ImageRef, encodedBytes: Int)?, Never>?
        do {
            try #require(await gate.waitUntilEntered())
            if cancelFirst { first.cancel() }
            second = Task { await worker.prepare(attachment, probe: nil) }
            let missing = OutboxAttachmentRef(id: UUID(), fileName: "missing.png", mimeType: "image/png", byteCount: 1)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-lease-\(UUID().uuidString)", isDirectory: true)
            persisted = Task { await worker.preparePersisted(entryId: "missing", attachment: missing,
                gatewayId: UUID(), root: root, probe: nil) }
            let deadline = ContinuousClock.now + .seconds(15)
            while await worker.pendingTestLeaseCount != 2 {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await worker.pendingTestLeaseCount == 2, "ordinary nil-probe callers cannot enter either preparation path while the actual lease is held")
            gate.open()
            let firstResult = await first.value
            let secondResult = await second?.value
            let persistedResult = await persisted?.value
            #expect(cancelFirst ? firstResult == nil : firstResult != nil)
            #expect(secondResult?.image.width == 1 && (secondResult?.encodedBytes ?? 0) > 0)
            #expect(persistedResult == nil, "missing persisted input retains the original nil result")
            #expect(await worker.pendingTestLeaseCount == 0)
        } catch {
            gate.open()
            await first.value
            await second?.value
            await persisted?.value
            throw error
        }
    }
}
#endif
