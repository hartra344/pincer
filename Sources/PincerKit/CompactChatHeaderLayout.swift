/// Geometry and backdrop policy consumed by the compact iOS identity header.
package enum CompactChatHeaderLayout {
    package static let avatarSize = ChatHeaderAvatarSize.small.avatarSize
    package static let minimumReservation = ChatHeaderAvatarSize.small.minimumReservation
    package static let navigationOverlap: Double = 44
    package static let fadeHeight: Double = 32
    package static let fadeMidpointOpacity: Double = 0.45
    package enum Backdrop: Sendable { case graduatedMaterial, opaque }
    package static func backdrop(reduceTransparency: Bool) -> Backdrop {
        reduceTransparency ? .opaque : .graduatedMaterial
    }
    package static func reservation(measuredTitleHeight: Double, scaledTitleAllowance: Double, size: ChatHeaderAvatarSize = .small) -> Double {
        let measured = measuredTitleHeight.isFinite ? max(0, measuredTitleHeight) : 0
        let allowance = scaledTitleAllowance.isFinite ? max(0, scaledTitleAllowance) : 22
        return max(size.minimumReservation, size.avatarSize + 4 + max(measured, allowance + 12) - navigationOverlap)
    }
}
