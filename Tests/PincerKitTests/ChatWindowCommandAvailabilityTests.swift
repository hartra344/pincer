import Foundation
import Testing
@testable import PincerKit

@Suite struct ChatWindowCommandAvailabilityTests {
    @Test func focusedOtherGatewayWorksWithoutMainAndStaleCannotFallback() {
        let main = ChatWindowCommandTarget(ref: .init(gatewayId: UUID(), sessionKey: "main"), isDetached: false)
        let front = ChatWindowCommandTarget(ref: .init(gatewayId: UUID(), sessionKey: "front"), isDetached: true)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: front) == front)
        #expect(ChatWindowCommandTarget.resolve(main: nil, focused: front) == front)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: front, isAvailable: { $0.gatewayId == main.ref.gatewayId }) == nil)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: nil, isAvailable: { $0 == main.ref }) == main)
    }
}
