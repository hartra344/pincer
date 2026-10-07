#if os(macOS) && DEBUG
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct QuickCaptureAttachmentReservationTests {
    @Test func actualFactoryReleasesFailedAndRejectedPreparation() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults, identity: UIFixtures.identity())
        let model = QuickCaptureModel(app: app, defaults: scratch.defaults)
        defer { scratch.remove() }
        let queue = BoundedPreparationQueue<AttachmentIngestResult>()
        let gate = QuickCaptureAttachmentPreparationTests.Gate()
        var report: String?
        let ingestion = QuickCaptureAttachmentIngest.make(model: model, imageQueue: queue, report: { report = $0 })
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        do {
            queue.submit(operation: { await gate.hold(); return .failure("owned gate") }, completion: { _ in })
            for _ in 0..<BoundedPreparationQueue<AttachmentIngestResult>.pendingItemLimit {
                queue.submit(operation: { .failure("owned pending") }, completion: { _ in })
            }
            ingestion.ingest([.data(Data([0]), type: .png, name: "rejected.png")])
            #expect(model.pendingAttachmentPreparations == 0 && model.attachments.isEmpty && report != nil)
            await gate.release()
            while queue.activeCount != 0 {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            report = nil
            ingestion.ingest([.data(Data([0]), type: .png, name: "invalid.png")])
            #expect(model.pendingAttachmentPreparations == 1)
            while queue.activeCount != 0 {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.pendingAttachmentPreparations == 0 && model.attachments.isEmpty && report != nil)
        } catch {
            await gate.release()
            let drain = Task { @MainActor in
                let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(25))
                while queue.activeCount != 0 && ContinuousClock.now < cleanupDeadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            await drain.value
            throw error
        }
    }


}
#endif
