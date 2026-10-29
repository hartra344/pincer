import Testing
@testable import PincerKit
@testable import PincerUI

// Why the header's thinking-level picker is disabled (#1086).
@MainActor
struct ThinkingLevelPickerTests {
    static func row(_ fields: JSONValue) -> SessionRow { SessionRow(fields)! }

    @Test func unavailableReasons() {
        let levels: JSONValue = [["id": "low", "label": "Low"], ["id": "high", "label": "High"]]
        let ready = Self.row(["key": "agent:main:main", "thinkingLevels": levels, "thinkingDefault": "low"])
        let menu = ThinkingLevelMenu(row: ready)
        #expect(ThinkingLevelPicker.unavailable(isConnected: true, row: ready, menu: menu) == nil)
        #expect(ThinkingLevelPicker.unavailable(isConnected: false, row: ready, menu: menu) == .disconnected, "offline wins")

        let placeholder = Self.row(["key": "agent:main:main", "thinkingLevels": levels, "pincerPlaceholder": true])
        #expect(ThinkingLevelPicker.unavailable(isConnected: true, row: placeholder, menu: ThinkingLevelMenu(row: placeholder)) == .placeholder)
        #expect(ThinkingLevelPicker.unavailable(isConnected: false, row: placeholder, menu: ThinkingLevelMenu(row: placeholder)) == .disconnected)

        let bare = Self.row(["key": "agent:main:main", "thinkingLevel": "ultra"])
        #expect(ThinkingLevelPicker.unavailable(isConnected: true, row: bare, menu: ThinkingLevelMenu(row: bare)) == .unsupported,
                "no levels reported: even Default can't be picked")
        for reason in [ThinkingLevelPicker.Unavailable.disconnected, .placeholder, .unsupported] {
            #expect(!ThinkingLevelPicker.reason(reason).isEmpty)
        }
    }
}
