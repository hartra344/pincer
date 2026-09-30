#if os(iOS)
import CoreGraphics
import Foundation
@testable import PincerKit
import Testing
import UIKit
@testable import PincerUI

/// #468: before the collection view has a real size, the UIKit list answers no visible rows.
@MainActor
@Suite("Transcript UIKit layout")
struct TranscriptUIKitLayoutTests {
    @Test func visibleRowsWaitForARealSize() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:list:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let coordinator = TranscriptList.Coordinator(context: context)
        let view = coordinator.makeCollectionView()
        _ = coordinator.controller.accept(TranscriptListControllerTests.rows(0..<10), contextChanged: false)
        #expect(view.bounds.height == 0)
        #expect(coordinator.visibleRows == nil)
        #expect(coordinator.rowWindow(screens: 1, minimum: 100) == nil)
    }
}
#endif
