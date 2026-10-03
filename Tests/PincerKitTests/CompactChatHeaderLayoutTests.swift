@testable import PincerKit
import Testing

@Suite("Compact graduated chat header layout")
struct CompactChatHeaderLayoutTests {
    @Test func defaultGeometryIsCompactAndFinishedTitleCanGrowThenShrink() {
        #expect(CompactChatHeaderLayout.avatarSize == 48)
        let ordinary = CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22)
        let accessible = CompactChatHeaderLayout.reservation(measuredTitleHeight: 76, scaledTitleAllowance: 48)
        #expect(ordinary == 44 && accessible > ordinary)
        #expect(CompactChatHeaderLayout.avatarSize + 4 + 76 - CompactChatHeaderLayout.navigationOverlap <= accessible)
        #expect(CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22) == ordinary)
        #expect(CompactChatHeaderLayout.reservation(measuredTitleHeight: .nan, scaledTitleAllowance: .infinity).isFinite)
    }
    @Test func reduceTransparencyUsesOpaqueBackdropWithoutFade() {
        #expect(CompactChatHeaderLayout.backdrop(reduceTransparency: false) == .graduatedMaterial)
        #expect(CompactChatHeaderLayout.backdrop(reduceTransparency: true) == .opaque)
        #expect(CompactChatHeaderLayout.fadeHeight > 0 && CompactChatHeaderLayout.fadeHeight < CompactChatHeaderLayout.minimumReservation)
    }
}
