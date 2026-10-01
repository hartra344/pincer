import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// The actual composer's localized title entry point, including its fallback.
@MainActor
@Suite("Chat chrome composer placeholder")
struct ChatChromeComposerTests {
    @Test func placeholderKeepsOnlyTheSelectedChatsLastKnownTitle() {
        let firstKey = "agent:main:dashboard:garden"
        let secondKey = "agent:main:dashboard:workbench"
        let garden = SessionRow(.object(["key": .string(firstKey), "label": "Garden"]))!
        let workbench = SessionRow(.object(["key": .string(secondKey), "label": "Workbench"]))!
        #expect(ChatView.composerPlaceholder(sessionKey: firstKey, current: garden, lastKnown: nil) == "Message #Garden")
        #expect(ChatView.composerPlaceholder(sessionKey: firstKey, current: nil, lastKnown: garden) == "Message #Garden")
        #expect(ChatView.composerPlaceholder(sessionKey: secondKey, current: workbench, lastKnown: garden) == "Message #Workbench")
        #expect(ChatView.composerPlaceholder(sessionKey: secondKey, current: nil, lastKnown: garden) == "Message #chat")
    }
}
