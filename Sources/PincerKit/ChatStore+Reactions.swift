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

    /// The quote card for a turn that replies to another message: yours by `replyToId`, the agent's by its
    /// delivery target (a transcript id, a bridged channel's message id, or a webchat send's idempotency key).
    public func quote(for item: ChatItem) -> ReplyQuote? {
        guard var targetId = item.replyToId else { return nil }
        if item.role == .assistant {
            guard let resolved = self.resolveAgentReplyTarget(targetId, for: item) else { return nil }
            targetId = resolved
        }
        if let target = self.message(withId: targetId) {
            let line = Replies.previewLine(MediaDirectives.extract(from: target.plainText).text)
            let sender: ReplyQuote.Sender = if let from = target.sender {
                .label(from.displayName(agents: self.gateway?.agents ?? []))
            } else if let name = target.channelSenderName {
                .label(name)
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

    /// The transcript id an assistant message's reply target names, or the raw id when its message isn't loaded.
    /// Nil when, in a direct chat, it's the user message the reply directly follows: nothing to point at.
    /// In a group the quote stays, since it says whose message was answered.
    private func resolveAgentReplyTarget(_ id: String, for item: ChatItem) -> String? {
        var targetId = id
        if self.message(withId: id) == nil,
           let match = self.items.first(where: { $0.role == .user && ($0.channelMessageId == id || $0.idempotencyKey == id) }),
           let matchId = match.transcriptId
        {
            targetId = matchId
        }
        if !self.isGroupChat, let index = self.items.firstIndex(where: { $0.id == item.id }),
           let answered = self.items[..<index].last(where: { $0.role == .user && $0.isReplyable }),
           answered.transcriptId == targetId
        {
            return nil
        }
        return targetId
    }

    private var isGroupChat: Bool {
        guard let row = self.gateway?.sessions[self.sessionKey] else { return false }
        return row.server != nil || row.chatType == "group" || row.chatType == "channel"
    }

    /// Transcript ids are 8 hex characters (or a UUID); channel message ids are other shapes.
    static func looksLikeTranscriptId(_ id: String) -> Bool {
        let hex = Set("0123456789abcdefABCDEF")
        if id.count == 8 { return id.allSatisfy(hex.contains) }
        return UUID(uuidString: id) != nil
    }

    /// `locate` for a quote tap. An id that can't be a transcript id is a bridged channel's message id
    /// that isn't in this chat, so there's nothing to page for.
    @discardableResult
    public func locateReplyTarget(_ id: String) async -> Bool {
        if self.message(withId: id) != nil { return true }
        guard Self.looksLikeTranscriptId(id) else {
            self.notice = "The original message isn't in this chat's history anymore."
            return false
        }
        return await self.locate(id)
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
        if self.usesGatewayReactions {
            return Reactions.groups(agent: self.agentReactions[messageId] ?? [], agentName: agentName,
                                    shared: self.sharedReactions[messageId] ?? [], selfId: self.reactionSelfId)
        }
        let mine = self.gateway?.myReactions(sessionKey: self.sessionKey, messageId: messageId) ?? []
        return Reactions.groups(agent: self.agentReactions[messageId] ?? [], agentName: agentName, mine: mine)
    }

    /// Your latest message while the agent works on it, for the transient 👀.
    public var ackMessageId: String? {
        let row = self.sessionRow ?? self.gateway?.sessions[self.sessionKey]
        let channel = row?.channel ?? row?.raw["lastChannel"]?.text
        let account = row?.raw["lastAccountId"]?.text ?? row?.raw["deliveryContext"]?["accountId"]?.text
            ?? row?.raw["origin"]?["accountId"]?.text
        return Reactions.ackTarget(items: self.items, isRunning: self.isRunning, runId: self.live?.runId,
                                  agentReactions: self.agentReactions, config: self.gateway?.settings.config,
                                  channel: channel, account: account, chatType: row?.chatType)
    }

    /// Adds `emoji` to the message, or removes it when it's already yours. Through the Gateway's shared
    /// reactions when it has them (it mirrors to the bridged channel and tells the agent); otherwise syncs
    /// through `users.prefs` and mirrors to the channel's message itself when the Gateway can.
    public func toggleReaction(_ emoji: String, on messageId: String) {
        guard self.message(withId: messageId) != nil else { return }
        if self.usesGatewayReactions, let selfId = self.reactionSelfId {
            self.toggleGatewayReaction(emoji, on: messageId, selfId: selfId)
        } else {
            self.toggleReactionViaPrefs(emoji, on: messageId)
        }
    }

    func toggleReactionViaPrefs(_ emoji: String, on messageId: String) {
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
