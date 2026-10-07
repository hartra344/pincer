import Foundation
import Testing
@testable import PincerKit

@Suite struct ChatWindowCommandTargetTests {
    @Test func detachedFrontChatSupersedesDifferentMainSelection() {
        let gateway = UUID()
        let main = ChatWindowCommandTarget(ref: .init(gatewayId: gateway, sessionKey: "agent:main:main"), isDetached: false)
        let front = ChatWindowCommandTarget(ref: .init(gatewayId: gateway, sessionKey: "agent:main:front"), isDetached: true)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: front) == front)
    }
    @Test func ordinaryMainAndFocusedSplitRemainMainContext() {
        let gateway = UUID()
        let main = ChatWindowCommandTarget(ref: .init(gatewayId: gateway, sessionKey: "agent:main:split"), isDetached: false)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: nil) == main)
        #expect(ChatWindowCommandTarget.resolve(main: main, focused: main) == main)
        #expect(ChatWindowCommandTarget.resolve(main: nil, focused: nil) == nil)
    }
}
