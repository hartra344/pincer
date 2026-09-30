import Foundation

/// Bookkeeping for one chat's Gateway reactions on a connection.
struct ReactionSync {
    /// The connection the list was requested on.
    var epoch: Int?
    var sessionId: String?
    var isListing = false
    /// Events seen while the list is in flight; they win over its snapshot.
    var eventUpdates: [String: [ReactionSummary]] = [:]
    /// Bumped per message by every event, so a set's response doesn't overwrite a newer event.
    var revisions: [String: Int] = [:]
    var migratedEpoch: Int?
}

extension ChatStore {
    /// Whether your reactions here are stored on the Gateway (shared, and seen by the agent on its next turn).
    public var usesGatewayReactions: Bool {
        guard let gateway, gateway.supportsSessionReactions else { return false }
        return self.reactionSelfId != nil && self.reactionSync.epoch == gateway.connectionEpoch
    }

    /// Reads the chat's reactions once per connection, then moves any `users.prefs` reactions over.
    func syncReactions() async {
        guard let gateway, gateway.state.isConnected, gateway.supportsSessionReactions else { return }
        let epoch = gateway.connectionEpoch
        guard self.reactionSync.epoch != epoch else { return }
        self.reactionSync.epoch = epoch
        self.reactionSync.isListing = true
        self.reactionSync.eventUpdates = [:]
        defer { self.reactionSync.isListing = false }
        guard let selfId = await gateway.selfProfileId() else { return }
        do {
            let result = try await gateway.connection.request(
                "session.reactions.list", .object(self.params(keyName: "sessionKey")), timeout: 15)
            guard gateway.connectionEpoch == epoch, self.reactionSync.epoch == epoch else { return }
            self.reactionSync.sessionId = result["sessionId"]?.text
            var map = ReactionSummary.parseMap(result["reactions"])
            for (id, list) in self.reactionSync.eventUpdates { map[id] = list.isEmpty ? nil : list }
            self.sharedReactions = map
            self.reactionSelfId = selfId
        } catch {
            guard gateway.connectionEpoch == epoch else { return }
            if Reactions.isGatewayReactionsUnavailable(error) {
                gateway.sessionReactionsOff = true
            } else if self.reactionSync.epoch == epoch {
                self.reactionSync.epoch = nil
            }
            return
        }
        self.reactionSync.isListing = false
        await self.migrateReactionPrefs(epoch: epoch, selfId: selfId)
    }

    /// `session.reaction`: replaces that message's reactions wholesale.
    func handleReactionEvent(_ payload: JSONValue) {
        guard let messageId = payload["messageId"]?.text else { return }
        if let sessionId = payload["sessionId"]?.text, let known = self.reactionSync.sessionId, sessionId != known { return }
        let list = ReactionSummary.parse(payload["reactions"])
        self.reactionSync.revisions[messageId, default: 0] += 1
        if self.reactionSync.isListing { self.reactionSync.eventUpdates[messageId] = list }
        if self.sharedReactions[messageId] != (list.isEmpty ? nil : list) {
            self.sharedReactions[messageId] = list.isEmpty ? nil : list
        }
    }

    /// Adds or removes your `emoji` through the Gateway: optimistic, reconciled with the response, rolled
    /// back on failure. A Gateway that can't do it sends this connection back to `users.prefs`.
    func toggleGatewayReaction(_ emoji: String, on messageId: String, selfId: String) {
        guard let gateway else { return }
        let before = self.sharedReactions[messageId] ?? []
        let removing = Reactions.mine(in: before, selfId: selfId).contains(emoji)
        if !removing { Reactions.noteRecent(emoji) }
        let after = Reactions.applying(emoji, remove: removing, to: before, selfId: selfId)
        self.sharedReactions[messageId] = after.isEmpty ? nil : after
        let revision = self.reactionSync.revisions[messageId, default: 0]
        let epoch = gateway.connectionEpoch
        let params = Reactions.setParams(sessionParams: self.params(keyName: "sessionKey"), messageId: messageId,
                                         emoji: emoji, remove: removing)
        Task { [weak self, weak gateway] in
            do {
                let result = try await gateway?.connection.request("session.reactions.set", .object(params), timeout: 30)
                guard let self, let gateway, gateway.connectionEpoch == epoch else { return }
                if self.reactionSync.revisions[messageId, default: 0] == revision, let result {
                    let list = ReactionSummary.parse(result["reactions"])
                    self.sharedReactions[messageId] = list.isEmpty ? nil : list
                }
                if result?["mirror"]?["status"]?.string == "failed",
                   gateway.reactionNoticeShown.insert(self.sessionKey).inserted
                {
                    self.notice = "The reaction couldn't be added in the chat's channel. It's saved on the Gateway."
                }
            } catch {
                guard let self, let gateway, gateway.connectionEpoch == epoch else { return }
                if self.reactionSync.revisions[messageId, default: 0] == revision {
                    self.sharedReactions[messageId] = before.isEmpty ? nil : before
                }
                if Reactions.isGatewayReactionsUnavailable(error) {
                    gateway.sessionReactionsOff = true
                    self.notice = "This Gateway can't share reactions, so they're saved in Pincer only."
                    self.toggleReactionViaPrefs(emoji, on: messageId)
                } else {
                    self.notice = "Couldn't save the reaction."
                }
            }
        }
    }

    /// Moves this chat's `users.prefs` reactions to the Gateway (once per connection); each entry is deleted
    /// once its reactions are there, or when the Gateway doesn't know the message.
    private func migrateReactionPrefs(epoch: Int, selfId: String) async {
        guard let gateway, self.reactionSync.migratedEpoch != epoch else { return }
        self.reactionSync.migratedEpoch = epoch
        let prefix = Reactions.prefEntryKey(sessionKey: self.sessionKey, messageId: "")
        let entries = gateway.reactions.filter { $0.key.hasPrefix(prefix) }
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let messageId = String(key.dropFirst(prefix.count))
            var done = true
            for emoji in Reactions.decode(value) {
                if Reactions.mine(in: self.sharedReactions[messageId] ?? [], selfId: selfId).contains(emoji) { continue }
                let params = Reactions.setParams(sessionParams: self.params(keyName: "sessionKey"),
                                                 messageId: messageId, emoji: emoji, remove: false)
                do {
                    let result = try await gateway.connection.request("session.reactions.set", .object(params), timeout: 30)
                    guard gateway.connectionEpoch == epoch else { return }
                    if self.reactionSync.revisions[messageId, default: 0] == 0 {
                        self.sharedReactions[messageId] = ReactionSummary.parse(result["reactions"])
                    }
                } catch {
                    guard gateway.connectionEpoch == epoch else { return }
                    if !Reactions.isUnknownMessage(error) { done = false }
                    if Reactions.isGatewayReactionsUnavailable(error) { return }
                }
            }
            if done { gateway.setReactions([], sessionKey: self.sessionKey, messageId: messageId) }
        }
    }
}
