import Foundation

/// Chats the user is looking at right now (#374). A chat counts as visible only while its scene is
/// active and focused and the chat itself is on screen (on iPhone: pushed, not just selected).
/// Anything that arrives in a visible chat is marked read at once; a chat that becomes visible
/// again (the app comes forward) is marked read then, so notifications and unread still work
/// while the user is away.
extension GatewayStore {
    /// The main window's viewer id for `setVisibleChat(_:viewer:)`.
    public static let mainViewer = "main"

    /// Chats visible in any viewer.
    public var visibleChatKeys: Set<String> { Set(self.visibleChatsByViewer.values) }

    /// Records which chat `viewer` (the main window, a chat window, ...) shows, or nil when it
    /// shows none or isn't active and focused.
    public func setVisibleChat(_ key: String?, viewer: String) {
        guard self.visibleChatsByViewer[viewer] != key else { return }
        self.visibleChatsByViewer[viewer] = key
        self.markVisibleChatsRead()
    }

    func markVisibleChatsRead() {
        guard self.state.isConnected, !self.visibleChatsByViewer.isEmpty else { return }
        for key in self.visibleChatKeys where self.sessions[key]?.isUnread == true {
            if self.markingRead.contains(key) {
                // Unread again (or still) while a patch is in flight: check once more when it lands.
                self.recheckRead.insert(key)
            } else {
                Task { await self.markRead(key) }
            }
        }
    }
}
