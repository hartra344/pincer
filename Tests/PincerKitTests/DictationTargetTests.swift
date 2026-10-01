import Foundation
import Testing
@testable import PincerKit

@Suite("Dictation target routing")
struct DictationTargetTests {
    @Test func aPaletteRequestMatchesOnlyTheActiveExactComposer() {
        let scene = UUID()
        let gateway = UUID()
        let sessionKey = "agent:main:dashboard:shared"
        let target = DictationTarget(sceneID: scene, gatewayID: gateway, sessionKey: sessionKey)
        let request = DictationToggleRequest(target: target, serial: 1)

        #expect(request.matches(target: target, paneIsActive: true))
        #expect(!request.matches(target: target, paneIsActive: false))
        #expect(!request.matches(target: DictationTarget(sceneID: UUID(), gatewayID: gateway, sessionKey: sessionKey), paneIsActive: true))
        #expect(!request.matches(target: DictationTarget(sceneID: scene, gatewayID: UUID(), sessionKey: sessionKey), paneIsActive: true))
        #expect(!request.matches(target: DictationTarget(sceneID: scene, gatewayID: gateway, sessionKey: "agent:main:dashboard:other"), paneIsActive: true))
    }

    @Test func targetsAreSafeSetKeysForWindowScopedPaletteState() {
        let first = DictationTarget(sceneID: UUID(), gatewayID: UUID(), sessionKey: "agent:main:dashboard:shared")
        let second = DictationTarget(sceneID: UUID(), gatewayID: first.gatewayID, sessionKey: first.sessionKey)
        var available: Set<DictationTarget> = [first]
        #expect(available.contains(first))
        #expect(!available.contains(second))
        available.insert(second)
        #expect(available.count == 2)
        available.remove(first)
        #expect(available == [second])
    }
}
