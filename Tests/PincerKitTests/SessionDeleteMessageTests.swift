import Foundation
import Testing
@testable import PincerKit

/// #213: the delete confirmation says how many unsent messages go with the chat.
@Suite("Session delete message")
struct SessionDeleteMessageTests {
    let base = SessionManager.deleteMessage

    @Test func noUnsentMessagesKeepTheOriginalText() {
        #expect(SessionManager.deleteMessage(unsentCount: 0) == self.base)
        #expect(SessionManager.deleteMessage(unsentCount: 0, sessionCount: 3) == self.base)
    }

    @Test func oneChat() {
        #expect(SessionManager.deleteMessage(unsentCount: 1) == self.base + " The 1 unsent message in this chat will be discarded too.")
        #expect(SessionManager.deleteMessage(unsentCount: 3) == self.base + " The 3 unsent messages in this chat will be discarded too.")
    }

    @Test func bulk() {
        #expect(SessionManager.deleteMessage(unsentCount: 1, sessionCount: 2)
            == self.base + " 1 unsent message in these chats will be discarded too.")
        #expect(SessionManager.deleteMessage(unsentCount: 4, sessionCount: 2)
            == self.base + " 4 unsent messages in these chats will be discarded too.")
    }

    @Test func numbersAreFormatted() {
        let big = 1234
        #expect(SessionManager.deleteMessage(unsentCount: big).contains(big.formatted()))
    }
}
