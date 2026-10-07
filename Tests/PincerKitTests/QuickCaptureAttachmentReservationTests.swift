import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct QuickCaptureAttachmentReservationTests {
    @Test func reservationsAreIdempotentAndOwnedByOneModel() throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults, identity: Fixtures.identity())
        let first = QuickCaptureModel(app: app, defaults: scratch.defaults)
        let other = QuickCaptureModel(app: app, defaults: scratch.defaults)
        defer { scratch.remove() }
        let finish = try #require(first.reserveAttachmentPreparation())
        let next = try #require(first.reserveAttachmentPreparation())
        #expect(first.pendingAttachmentPreparations == 2 && other.pendingAttachmentPreparations == 0)
        finish(); finish()
        #expect(first.pendingAttachmentPreparations == 1)
        next(); next()
        #expect(first.pendingAttachmentPreparations == 0)
    }
}
