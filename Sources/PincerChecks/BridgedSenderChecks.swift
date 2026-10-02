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
}
