import Testing
@testable import PincerKit

@Suite struct ChatWindowTitleQualifierTests {
    @Test func detachedQualifierRetainsTheCompleteChatName() {
        let title = "Main — Research · notes"
        #expect(ChatWindowTitle.title(title, isDetached: false) == title)
        #expect(ChatWindowTitle.title(title, isDetached: true) == "Main — Research · notes — Chat window")
    }
}
