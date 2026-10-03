import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Centered chat current identity")
struct CenteredChatHeaderTitleTests {
    @Test func actualHeaderTitleTracksCurrentRowsAndNeverBorrowsAnotherChatsCachedTitle() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Header title", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let tripKey = "agent:main:dashboard:trip", gardenKey = "agent:main:dashboard:garden"
        let trip = SessionRow(.object(["key": .string(tripKey), "label": "Weekend trip"]))!
        let garden = SessionRow(.object(["key": .string(gardenKey), "label": "Garden planning"]))!
        gateway.setSession(trip, for: tripKey)
        gateway.setSession(garden, for: gardenKey)
        gateway.selectedKey = tripKey
        gateway.rememberTitle("Weekend trip", for: tripKey)
        #expect(chatTitle(gateway, key: tripKey, row: trip) == "Weekend trip")
        #expect(chatTitle(gateway, key: tripKey, row: nil) == "Weekend trip")
        gateway.selectedKey = gardenKey
        gateway.rememberTitle("Garden planning", for: gardenKey)
        #expect(chatTitle(gateway, key: gardenKey, row: garden) == "Garden planning")
        #expect(chatTitle(gateway, key: gardenKey, row: nil) == "Garden planning")
        let renamed = SessionRow(.object(["key": .string(gardenKey), "label": "Garden next steps"]))!
        gateway.setSession(renamed, for: gardenKey)
        #expect(chatTitle(gateway, key: gardenKey, row: renamed) == "Garden next steps")
        #expect(chatTitle(gateway, key: tripKey, row: trip) == "Weekend trip")
        #expect(chatTitle(gateway, key: tripKey, row: nil) == PincerUI.L("Chat"),
                "A no-longer-visible cache entry cannot borrow the current Garden title")
    }
}
