import Foundation

/// Gateway-level reactions: `users.self`, `session.reactions.list/set` and the `session.reaction` event,
/// like openclaw/openclaw#161053. Reactions are shared per message, with each reactor's identity.
extension DemoGateway {
    static let reactionMethods = ["users.self", "session.reactions.set", "session.reactions.list"]
    static let selfProfile = (id: "demo-owner", label: "You")

    var advertisedMethods: [String] {
        self.hasSessionReactions ? Self.methods + Self.reactionMethods : Self.methods
    }

    struct DemoReaction {
        var emoji: String
        var people: [(id: String, label: String)]
    }

    /// Reactions from other people alongside yours, in the chat Pincer opens on.
    static func seedSessionReactions() -> [String: [String: [DemoReaction]]] {
        let me = Self.selfProfile
        let sam = (id: "sam", label: "Sam")
        let riley = (id: "riley", label: "Riley")
        let key = "agent:main:main"
        return [
            key: [
                "demo-main-status": [
                    DemoReaction(emoji: "👍", people: [me, sam]),
                    DemoReaction(emoji: "🔥", people: [riley]),
                ],
                "demo-main-gauge": [DemoReaction(emoji: "🎉", people: [sam, riley])],
                "demo-main-ask": [DemoReaction(emoji: "🙏", people: [sam])],
            ],
        ]
    }

    func handleReactions(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard self.hasSessionReactions, Self.reactionMethods.contains(method) else { return nil }
        switch method {
        case "users.self":
            let me = Self.selfProfile
            return ["profile": ["id": .string(me.id), "displayName": .string(me.label), "emails": [],
                                "updatedAt": Self.now()]]
        case "session.reactions.list":
            let key = try self.knownSession(params["sessionKey"])
            var reactions: [String: JSONValue] = [:]
            for (messageId, list) in self.sessionReactions[key] ?? [:] { reactions[messageId] = self.reactionSummaries(list) }
            return ["sessionId": self.sessions[key]?["sessionId"] ?? .null, "reactions": .object(reactions)]
        case "session.reactions.set":
            return try self.setReaction(params)
        default:
            return nil
        }
    }

    func reactionSummaries(_ list: [DemoReaction]) -> JSONValue {
        JSONValue.array(list.filter { !$0.people.isEmpty }.map { reaction -> JSONValue in
            [
                "emoji": .string(reaction.emoji), "count": .number(Double(reaction.people.count)),
                "identities": JSONValue.array(reaction.people.map { ["id": .string($0.id), "label": .string($0.label)] as JSONValue }),
            ]
        })
    }

    func setReaction(_ params: JSONValue) throws -> JSONValue {
        let key = try self.knownSession(params["sessionKey"])
        guard let messageId = params["messageId"]?.text, !messageId.isEmpty else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid session.reactions.set params: messageId is required", details: nil)
        }
        guard let emoji = params["emoji"]?.text, Self.isReactionEmoji(emoji) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "one emoji grapheme is required", details: nil)
        }
        let message = self.transcripts[key]?.first { $0["__openclaw"]?["id"]?.text == messageId }
        guard let message, ["user", "assistant"].contains(message["role"]?.text) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown message", details: nil)
        }
        let remove = params["remove"]?.bool == true
        let me = Self.selfProfile
        var list = self.sessionReactions[key]?[messageId] ?? []
        let index = list.firstIndex { $0.emoji == emoji }
        let had = index.map { list[$0].people.contains { $0.id == me.id } } ?? false
        let changed = remove ? had : !had
        if changed {
            if remove, let index {
                list[index].people.removeAll { $0.id == me.id }
                if list[index].people.isEmpty { list.remove(at: index) }
            } else if let index {
                list[index].people.append(me)
            } else {
                list.append(DemoReaction(emoji: emoji, people: [me]))
            }
            self.sessionReactions[key, default: [:]][messageId] = list.isEmpty ? nil : list
        }
        let reactions = self.reactionSummaries(list)
        let transported = message["role"]?.text == "user" && message["__openclaw"]?["transport"] != nil
        let mirror: JSONValue = !changed
            ? ["status": "skipped", "reason": "reaction already in that state"]
            : transported ? ["status": "delivered"]
            : ["status": "skipped", "reason": "message has no source channel transport"]
        if changed {
            let row = self.sessions[key]
            self.emit("session.reaction", [
                "sessionKey": .string(key), "agentId": row?["agentId"] ?? "main", "sessionId": row?["sessionId"] ?? .null,
                "messageId": .string(messageId), "emoji": .string(emoji), "action": remove ? "removed" : "added",
                "actor": ["type": "human", "id": .string(me.id), "label": .string(me.label)], "reactions": reactions,
            ])
        }
        return ["messageId": .string(messageId), "reactions": reactions, "mirror": mirror]
    }

    /// One emoji grapheme of at most 32 characters.
    static func isReactionEmoji(_ value: String) -> Bool {
        guard !value.isEmpty, value.count == 1, value.utf16.count <= 32, let first = value.unicodeScalars.first else { return false }
        return value.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }
            || (first.properties.isEmoji && value.unicodeScalars.contains { $0.value == 0x20E3 })
    }
}
