import Foundation
import Testing
@testable import PincerKit

/// While Clear Cache deletes a Gateway's index files, no index for it opens a file (#153): a save
/// in that window gets an inert stand-in instead of recreating the index on a file about to go.
/// Only the registry is exercised, so nothing here touches the real cache folder.
@Suite("Message index discard")
struct MessageIndexDiscardTests {
    @Test func sharedReturnsAStandInWhileFilesAreDeleted() {
        let id = UUID(), other = UUID()
        let before = MessageIndex.shared(gatewayId: id)
        #expect(MessageIndex.shared(gatewayId: id) === before, "one shared index per Gateway")
        let untouched = MessageIndex.shared(gatewayId: other)
        var ran = false
        let result = MessageIndex.discard([id]) { () -> Int in
            ran = true
            let standIn = MessageIndex.shared(gatewayId: id)
            #expect(standIn !== before, "the discarded index isn't handed out")
            #expect(MessageIndex.shared(gatewayId: id) !== standIn, "stand-ins aren't registered")
            #expect(MessageIndex.shared(gatewayId: other) === untouched, "other Gateways keep their index")
            return 42
        }
        #expect(ran && result == 42, "deleteFiles runs once and its result is returned")
        let after = MessageIndex.shared(gatewayId: id)
        #expect(after !== before, "a fresh index after deleting")
        #expect(MessageIndex.shared(gatewayId: id) === after, "and it's shared again")
        #expect(!MessageIndex.isDiscardedPermanently(gatewayId: id))
    }

    @Test func overlappingDiscardsKeepTheStandInUntilTheLastEnds() {
        let id = UUID()
        _ = MessageIndex.shared(gatewayId: id)
        MessageIndex.discard([id]) {
            MessageIndex.discard([id]) {}
            let first = MessageIndex.shared(gatewayId: id)
            #expect(MessageIndex.shared(gatewayId: id) !== first, "still deleting: stand-ins only")
        }
        let registered = MessageIndex.shared(gatewayId: id)
        #expect(MessageIndex.shared(gatewayId: id) === registered)
    }

    @Test func permanentDiscardIsRemembered() {
        let id = UUID()
        _ = MessageIndex.shared(gatewayId: id)
        MessageIndex.discard([id], permanently: true) {}
        #expect(MessageIndex.isDiscardedPermanently(gatewayId: id))
    }
}
