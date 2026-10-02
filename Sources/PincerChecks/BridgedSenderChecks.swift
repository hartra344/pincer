import PincerKit

/// The transcript header uses the same parsed author resolver as reply quotes.
@MainActor
func checkBridgedHeaderAuthors() {
    let bridged = ChatItem(json(#"{"role":"user","content":"Can you find the pediatrician's opening hours?","senderLabel":"Maya","__openclaw":{"senderName":"Maya"}}"#), fallbackIndex: 0)
    check(bridged?.senderName(you: "Travis", agent: "Claw", agents: []) == "Maya",
          "bridged row authors: parsed sender wins over the device owner's name")
    let local = ChatItem(json(#"{"role":"user","content":"A local message"}"#), fallbackIndex: 0)
    check(local?.senderName(you: "Travis", agent: "Claw", agents: []) == "Travis",
          "bridged row authors: an unnamed local message retains the owner")
    check(local?.senderName(you: "Alex", agent: "Claw", agents: []) == "Alex",
          "bridged row authors: the fallback follows the current owner name")
    check(AccessibilityText.messageRow(role: .user, userAuthor: bridged?.channelSenderName, text: "Hello")
            .hasPrefix("Maya"), "bridged row authors: VoiceOver names the parsed person")
    check(AccessibilityText.speaker(role: .user, author: "Device Owner") == AccessibilityText.speaker(role: .user),
          "bridged row authors: the existing local VoiceOver contract stays unchanged")
    check(AccessibilityText.speaker(role: .user, userAuthor: "  \n") == AccessibilityText.speaker(role: .user),
          "bridged row authors: an empty bridged name retains the local VoiceOver fallback")
}
