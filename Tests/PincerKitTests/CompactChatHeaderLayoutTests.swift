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
        #expect(CompactChatHeaderLayout.minimumReservation == ordinary)
        #expect(CompactChatHeaderLayout.avatarSize + 4 + 76 - CompactChatHeaderLayout.navigationOverlap <= accessible)
        #expect(CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22) == ordinary)
        #expect(CompactChatHeaderLayout.reservation(measuredTitleHeight: .nan, scaledTitleAllowance: .infinity).isFinite)
    }
    @Test func reduceTransparencyUsesOpaqueBackdropWithoutFade() {
        #expect(CompactChatHeaderLayout.backdrop(reduceTransparency: false) == .graduatedMaterial)
        #expect(CompactChatHeaderLayout.backdrop(reduceTransparency: true) == .opaque)
        #expect(CompactChatHeaderLayout.reservation(measuredTitleHeight: 32, scaledTitleAllowance: 22) == 44)
        #expect(CompactChatHeaderLayout.navigationOverlap == 44)
    }
    @Test func graduatedFadeIsEasedMonotonicAndReachesPastTheOldBand() {
        let stops = CompactChatHeaderLayout.defaultFadeStops
        #expect(stops.count == CompactChatHeaderLayout.fadeStopCount && stops.count >= 12)
        #expect(stops.first == .init(location: 0, opacity: 1) && stops.last == .init(location: 1, opacity: 0))
        for (a, b) in zip(stops, stops.dropFirst()) {
            #expect(b.location > a.location && b.opacity <= a.opacity)
        }
        let drops = zip(stops, stops.dropFirst()).map { $0.opacity - $1.opacity }
        let middle = drops[drops.count / 2]
        #expect(drops.first! < middle / 3 && drops.last! < middle / 3)
        #expect(drops.max()! < 0.2)
        #expect(CompactChatHeaderLayout.fadeOpacity(at: 0.5) == 0.5)
        #expect(CompactChatHeaderLayout.fadeOpacity(at: -1) == 1 && CompactChatHeaderLayout.fadeOpacity(at: .nan) == 0)
        #expect(CompactChatHeaderLayout.fadeStops(count: 0).count == 2)
        // The base blur's tail reaches past the old 32 pt band and below the reservation, and its
        // ramp starts above the title pill, so text beside the pill hands off gradually.
        #expect(CompactChatHeaderLayout.fadeHeight == 88 && CompactChatHeaderLayout.fadeExtension == 40)
        #expect(CompactChatHeaderLayout.fadeMaterial == .ultraThin && CompactChatHeaderLayout.progressiveMaterial == .regular)
        for size in ChatHeaderAvatarSize.allCases {
            let reservation = size.minimumReservation
            let depth = CompactChatHeaderLayout.backdropDepth(reservation: reservation)
            let blur = CompactChatHeaderLayout.blurRamp(reservation: reservation)
            let wash = CompactChatHeaderLayout.washRamp(size: size)
            let pillTop = size.avatarSize + 4
            #expect(depth == CompactChatHeaderLayout.navigationOverlap + reservation + 40 && blur.end == depth)
            #expect(blur.start < pillTop && blur.length == 88)
            // The wash holds to the avatar's bottom, then fades out across the pill, before the blur does.
            #expect(wash.start == size.avatarSize && wash.end > pillTop && wash.end <= blur.end)
            let progressiveAtPill = (pillTop - CompactChatHeaderLayout.progressiveRamp.start) / CompactChatHeaderLayout.progressiveRamp.length
            #expect(CompactChatHeaderLayout.fadeOpacity(at: progressiveAtPill) < 0.01 && CompactChatHeaderLayout.progressiveRamp.end < wash.end)
        }
        let progressive = CompactChatHeaderLayout.progressiveRamp
        #expect(progressive.start >= 0 && progressive.length > 0)
        #expect(CompactChatHeaderLayout.progressiveWashOpacity == 0.5 && CompactChatHeaderLayout.fadeMaterialWashOpacity == 0.6)
        #expect(CompactChatHeaderLayout.washOpacity(dark: false) == 0.8 && CompactChatHeaderLayout.washOpacity(dark: true) == 0.85)
    }
}
