import Foundation
import PincerKit

@MainActor func runChatWindowCommandAvailabilityChecks() {
    let main = ChatWindowCommandTarget(ref: .init(gatewayId: UUID(), sessionKey: "main"), isDetached: false)
    let front = ChatWindowCommandTarget(ref: .init(gatewayId: UUID(), sessionKey: "front"), isDetached: true)
    check(ChatWindowCommandTarget.resolve(main: nil, focused: front) == front, "detached other-gateway context works without main selection")
    check(ChatWindowCommandTarget.resolve(main: main, focused: front, isAvailable: { $0.gatewayId == main.ref.gatewayId }) == nil,
          "stale focused gateway disables command rather than falling back to main")
    check(ChatWindowCommandTarget.resolve(main: main, focused: nil, isAvailable: { $0 == main.ref }) == main,
          "available main context remains supported")
}
