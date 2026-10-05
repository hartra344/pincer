import Testing
@testable import PincerKit

@Suite struct ChatWindowTitleTests {
    @Test func sameChatWindowsHaveDistinctNativeTitles() {
        let main = ChatWindowTitle.title("Main", isDetached: false)
        let detached = ChatWindowTitle.title("Main", isDetached: true)
        #expect(main == "Main")
        #expect(!detached.isEmpty && detached != main)
    }
    @Test func ordinaryMainTitleIsPreserved() {
        #expect(ChatWindowTitle.title("Rate limiter design", isDetached: false) == "Rate limiter design")
    }
}
