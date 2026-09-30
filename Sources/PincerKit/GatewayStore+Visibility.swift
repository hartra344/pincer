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
        // Seen now, so a reply still waiting to be marked unread (#426) was read.
        if let key, self.pendingReplyUnread.remove(key) != nil { self.replyUnreadTimers[key]?.cancel() }
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

/// Replies that land in a chat nobody is viewing (#426). Released Gateways only turn a chat unread when
/// the user sends (`lastInteractionAt`), and Pincer reads the chat on screen as the user sends (#374),
/// so the reply that follows never shows. openclaw/openclaw#155690 fixes that on the Gateway; until
/// every supported Gateway has it, Pincer marks the chat unread itself. Where the Gateway already did,
/// the row is unread and nothing is sent.
extension GatewayStore {
    /// How long a finished reply waits for the Gateway's own row change (and for a window that is
    /// opening on the chat) before Pincer marks it.
    static let defaultReplyUnreadGrace: Duration = .milliseconds(1500)

    /// Records that `key`'s finished reply has been decided (marked, or deliberately not); tests wait on it.
    func replyUnreadDecided(_ key: String) {
        self.replyUnreadDecisions[key, default: 0] += 1
    }

    /// Called when a run's reply finishes in `key`.
    func noteReplyLanded(_ key: String, runId: String?, message: JSONValue?) {
        guard self.bootstrapped, let message, !message.isNull else { return }
        if let runId {
            guard !self.markedReplyRuns.contains(runId) else { return }
            if self.markedReplyRuns.count >= 200 { self.markedReplyRuns.removeAll() }
            self.markedReplyRuns.insert(runId)
        }
        guard !self.visibleChatKeys.contains(key) else { return self.replyUnreadDecided(key) }
        let replyAt = message["timestamp"]?.double ?? Date().timeIntervalSince1970 * 1000
        self.pendingReplyUnread.insert(key)
        let grace = self.replyUnreadGrace
        self.replyUnreadTimers[key] = Task { [weak self] in
            // Cancelled when the chat is shown: the sleep ends early and the decision is "read".
            try? await Task.sleep(for: grace)
            guard let self else { return }
            defer { self.replyUnreadDecided(key) }
            guard self.pendingReplyUnread.remove(key) != nil,
                  self.state.isConnected, !self.visibleChatKeys.contains(key),
                  let row = self.sessions[key], Self.shouldMarkReplyUnread(row: row, replyAt: replyAt)
            else { return }
            await self.patch(key, ["unread": true])
        }
    }

    /// Whether a reply at `replyAt` (ms) should turn `row` unread: it isn't already, it's a chat of the
    /// user's own, and nobody read it after the reply (another device, say).
    static func shouldMarkReplyUnread(row: SessionRow, replyAt: Double) -> Bool {
        guard !row.isUnread, !row.isSubagent, !row.isArchived else { return false }
        let readAt = row.raw["lastReadAt"]?.double ?? 0
        let endedAt = row.raw["endedAt"]?.double ?? 0
        return readAt < max(replyAt, endedAt)
    }
}
