@testable import PincerKit
import Testing

@Suite("Compact graduated chat header layout")
struct CompactChatHeaderLayoutTests {
    @Test func devicePreferenceDefaultsNormalizesWithoutWritingAndPersistsChoice() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(ChatHeaderAvatarSize.load(from: scratch.defaults) == .small)
        #expect(scratch.defaults.object(forKey: ChatHeaderAvatarSize.defaultsKey) == nil)
        scratch.defaults.set("future-size", forKey: ChatHeaderAvatarSize.defaultsKey)
        #expect(ChatHeaderAvatarSize.load(from: scratch.defaults) == .small)
        #expect(scratch.defaults.string(forKey: ChatHeaderAvatarSize.defaultsKey) == "future-size")
        for size in ChatHeaderAvatarSize.allCases {
            scratch.defaults.set(size.rawValue, forKey: ChatHeaderAvatarSize.defaultsKey)
            #expect(ChatHeaderAvatarSize.load(from: scratch.defaults) == size)
            let base = CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22, size: size)
            let grown = CompactChatHeaderLayout.reservation(measuredTitleHeight: 100, scaledTitleAllowance: 48, size: size)
            #expect(base == size.minimumReservation && grown > base)
            #expect(size.avatarSize + 4 + 100 - CompactChatHeaderLayout.navigationOverlap <= grown)
        }
    }
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
        #expect(CompactChatHeaderLayout.fadeMidpointOpacity == 0.45)
        #expect(CompactChatHeaderLayout.fadeHeight == 32)
        #expect(CompactChatHeaderLayout.fadeHeight > 0 && CompactChatHeaderLayout.fadeHeight < CompactChatHeaderLayout.minimumReservation)
    }
}
