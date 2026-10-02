import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Sidebar section work")
struct SidebarSectionWorkTests {
    @Test func derivesEachVisibleRowsParentsAtMostOnce() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let count = 300
        let rows = (0..<count).map { index in
            #"{"key":"agent:main:dashboard:chat\#(index)","updatedAt":\#(index)}"#
        }
        let store = GatewayStore(
            profile: GatewayProfile(name: "Sidebar work", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: Fixtures.identity())
        store.applySnapshot(Fixtures.json(#"{"sessions":[\#(rows.joined(separator: ","))]}"#))

        store.sidebarParentCandidateDerivationCount = 0
        _ = store.sections()

        #expect(store.sidebarParentCandidateDerivationCount <= count)
    }
}
