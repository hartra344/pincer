import Foundation
import Observation

extension ChatStore {
    // MARK: Replies

    /// A loaded, committed message by transcript id.
    public func message(withId id: String) -> ChatItem? {
        self.itemsByTranscriptId[id]
    }

    /// What a Reply on `messageId` would target. `you` and `agent` name the senders.
    public func replyTarget(for messageId: String, you: String, agent: String) -> ReplyTarget? {
        guard let item = self.message(withId: messageId) else { return nil }
        let text = MediaDirectives.extract(from: item.plainText).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.isEmpty ? (item.blocks.contains { if case .image = $0 { true } else { false } } ? "Image" : "Attachment") : text
        return ReplyTarget(messageId: messageId, senderLabel: item.senderName(you: you, agent: agent, agents: self.gateway?.agents ?? []),
                           preview: preview, isAssistant: item.role == .assistant)
    }

    /// The newest committed message a reply can target (for ⇧⌘R).
    public var latestReplyableId: String? {
        self.items.last { item in
            item.isReplyable && (item.role == .user || !item.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }?.transcriptId
    }

    /// The quote card for a user turn that replies to another message.
    public func quote(for item: ChatItem) -> ReplyQuote? {
        guard let targetId = item.replyToId else { return nil }
        if let target = self.message(withId: targetId) {
            let line = Replies.previewLine(MediaDirectives.extract(from: target.plainText).text)
            let sender: ReplyQuote.Sender = if let from = target.sender {
                .label(from.displayName(agents: self.gateway?.agents ?? []))
            } else {
                target.role == .user ? .you : .agent
            }
            return ReplyQuote(targetId: targetId, sender: sender,
                              text: line.isEmpty ? item.replyToPreview?.text : line)
        }
        if let preview = item.replyToPreview {
            return ReplyQuote(targetId: targetId, sender: preview.senderLabel.map { .label($0) },
                              text: Replies.previewLine(preview.text))
        }
        return ReplyQuote(targetId: targetId, sender: nil, text: nil)
    }

    /// Loads older history (the cache first) until the message is loaded (at most 40 pages). Returns whether it is;
    /// when history runs out or the page cap is hit, says so in `notice`. One lookup at a time.
    @discardableResult
    public func locate(_ id: String) async -> Bool {
        if self.message(withId: id) != nil { return true }
        guard self.locatingReplyId == nil else { return false }
        self.locatingReplyId = id
        defer { self.locatingReplyId = nil }
        while self.olderInCache, !Task.isCancelled {
            guard await self.loadOlder(cachePageSize: Int.max, stopAt: id) else { return false }
            if self.message(withId: id) != nil { return true }
        }
        for _ in 0..<40 where self.hasMoreHistory {
            guard await self.loadOlder() else { return false }
            if self.message(withId: id) != nil { return true }
        }
        if self.message(withId: id) != nil { return true }
        self.notice = self.hasOlderItems
            ? "The original message is too far back to show."
            : "The original message isn't in this chat's history anymore."
        return false
    }

    // MARK: Reactions

    /// Emoji reactions on one message: the agent's first, then yours.
    public func reactionGroups(for messageId: String, agentName: String) -> [ReactionGroup] {
        let mine = self.gateway?.myReactions(sessionKey: self.sessionKey, messageId: messageId) ?? []
        return Reactions.groups(agent: self.agentReactions[messageId] ?? [], agentName: agentName, mine: mine)
    }

    /// Your latest message while the agent works on it, for the transient 👀.
    public var ackMessageId: String? {
        Reactions.ackTarget(items: self.items, isRunning: self.isRunning, runId: self.live?.runId,
                            agentReactions: self.agentReactions)
    }

    /// Adds `emoji` to the message, or removes it when it's already yours. Syncs through
    /// `users.prefs`, and mirrors it to the bridged channel's message when the Gateway can.
    public func toggleReaction(_ emoji: String, on messageId: String) {
        guard let gateway, let item = self.message(withId: messageId) else { return }
        let mine = gateway.myReactions(sessionKey: self.sessionKey, messageId: messageId)
        let removing = mine.contains(emoji)
        if !removing { Reactions.noteRecent(emoji) }
        gateway.setReactions(Reactions.toggling(emoji, in: mine), sessionKey: self.sessionKey, messageId: messageId)
        self.forwardReaction(emoji, remove: removing, on: item)
    }

    func forwardReaction(_ emoji: String, remove: Bool, on item: ChatItem) {
        guard let gateway, gateway.supportsMessageAction, item.role == .user,
              let channelMessageId = item.channelMessageId
        else { return }
        let row = gateway.sessions[self.sessionKey]
        guard let sessionChannel = row?.channel ?? row?.raw["lastChannel"]?.text ?? item.transportChannel,
              sessionChannel != "webchat", sessionChannel != "internal"
        else { return }
        let channel = item.transportChannel ?? sessionChannel
        guard !gateway.reactionForwardingOff.contains(channel) else { return }
        let params = Reactions.messageActionParams(
            channel: channel, sessionKey: self.sessionKey, channelMessageId: channelMessageId, emoji: emoji,
            remove: remove, conversationRef: item.conversationRef, idempotencyKey: UUID().uuidString.lowercased())
        let epoch = gateway.connectionEpoch
        Task { [weak self, weak gateway] in
            do {
                _ = try await gateway?.connection.request("message.action", .object(params), timeout: 30)
            } catch {
                guard let self, let gateway, gateway.connectionEpoch == epoch else { return }
                if Reactions.isUnsupported(error) { gateway.reactionForwardingOff.insert(channel) }
                if gateway.reactionNoticeShown.insert(self.sessionKey).inserted {
                    self.notice = "Couldn't add the reaction in \(channel.capitalized). It's saved in Pincer only."
                }
            }
        }
    }

    func params(keyName: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = [keyName: .string(self.sessionKey)]
        if let agentId, SessionKey.agentId(from: self.sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        return params
    }
}
