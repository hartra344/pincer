/// Geometry and backdrop policy consumed by the compact iOS identity header.
package enum CompactChatHeaderLayout {
    package static let avatarSize = ChatHeaderAvatarSize.small.avatarSize
    package static let minimumReservation = ChatHeaderAvatarSize.small.minimumReservation
    package static let navigationOverlap: Double = 44
    package enum Backdrop: Sendable { case graduatedMaterial, opaque }
    package static func backdrop(reduceTransparency: Bool) -> Backdrop {
        reduceTransparency ? .opaque : .graduatedMaterial
    }
    package static func reservation(measuredTitleHeight: Double, scaledTitleAllowance: Double, size: ChatHeaderAvatarSize = .small) -> Double {
        let measured = measuredTitleHeight.isFinite ? max(0, measuredTitleHeight) : 0
        let allowance = scaledTitleAllowance.isFinite ? max(0, scaledTitleAllowance) : 22
        return max(size.minimumReservation, size.avatarSize + 4 + max(measured, allowance + 12) - navigationOverlap)
    }

    // MARK: Graduated backdrop (#1097)
    //
    // Three static layers, each with its own eased ramp (1 − smootherstep, `fadeStopCount` stops):
    // 1. `fadeMaterial` (base blur) with a `fadeMaterialWashOpacity` chat-background wash inside:
    //    full from the top of the screen, ramping to zero over `fadeHeight`, ending `fadeExtension`
    //    below the reservation.
    // 2. `progressiveMaterial` with a `progressiveWashOpacity` chat-background wash inside: a second,
    //    stronger blur only near the top (`progressiveRamp`), approximating a progressive blur.
    // 3. A chat-background wash (`washOpacity`): full down to the avatar's bottom, then ramping to
    //    zero over `washFadeLength`, across the title pill.
    // Ramp offsets are measured from the chrome top: the avatar's top edge, `navigationOverlap`
    // above the reservation. On an iPhone 17 Pro that is 10 pt below the status bar.
    // These are the tuning knobs.

    package enum FadeMaterial: Sendable { case ultraThin, regular }
    package static let fadeMaterial: FadeMaterial = .ultraThin
    /// Chat-background wash inside the base blur, following its ramp, so the material's grey tint
    /// never shows as a band once the top wash has faded.
    package static let fadeMaterialWashOpacity: Double = 0.6
    /// Length of the base blur's eased ramp; it ends `fadeExtension` below the reservation's bottom edge.
    package static let fadeHeight: Double = 88
    /// How far the base blur's tail reaches past the reservation into the transcript.
    package static let fadeExtension: Double = 40
    package static let progressiveMaterial: FadeMaterial = .regular
    package static let progressiveRamp = FadeRamp(start: 6, end: 54)
    package static let progressiveWashOpacity: Double = 0.5
    /// Peak opacity of the chat-background wash, so the status-bar zone reads as the page background.
    package static func washOpacity(dark: Bool) -> Double { dark ? 0.85 : 0.8 }
    package static let washFadeLength: Double = 32
    package static let fadeStopCount = 16

    package struct FadeStop: Equatable, Sendable {
        package let location: Double
        package let opacity: Double
    }

    /// A ramp from full (`start`) to clear (`end`), in points below the chrome top.
    package struct FadeRamp: Equatable, Sendable {
        package let start: Double
        package let end: Double
        package var length: Double { self.end - self.start }
    }

    /// Height of the backdrop below the chrome top; above it every layer is at full strength.
    package static func backdropDepth(reservation: Double) -> Double {
        navigationOverlap + reservation + fadeExtension
    }

    package static func blurRamp(reservation: Double) -> FadeRamp {
        let end = self.backdropDepth(reservation: reservation)
        return FadeRamp(start: end - fadeHeight, end: end)
    }

    package static func washRamp(size: ChatHeaderAvatarSize = .small) -> FadeRamp {
        FadeRamp(start: size.avatarSize, end: size.avatarSize + washFadeLength)
    }

    /// Mask opacity at `progress` (0 = start of the ramp, 1 = end): 1 − smootherstep, whose first and
    /// second derivatives vanish at both ends, so neither end of the ramp shows a band edge.
    package static func fadeOpacity(at progress: Double) -> Double {
        let t = progress.isFinite ? min(1, max(0, progress)) : 1
        return 1 - t * t * t * (t * (t * 6 - 15) + 10)
    }

    package static func fadeStops(count: Int) -> [FadeStop] {
        let count = max(2, count)
        return (0..<count).map { index in
            let location = Double(index) / Double(count - 1)
            return FadeStop(location: location, opacity: self.fadeOpacity(at: location))
        }
    }

    /// Computed once; the header never recomputes the curve while scrolling.
    package static let defaultFadeStops = fadeStops(count: fadeStopCount)
}
