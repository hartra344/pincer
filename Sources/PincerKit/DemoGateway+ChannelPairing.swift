import Foundation

/// Channel pairing requests.
extension DemoGateway {
    func handleChannelPairing(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "channels.pairing.list":
            return self.pairingList()
        case "channels.pairing.approve":
            return try self.resolvePairing(params, approve: true)
        case "channels.pairing.dismiss":
            return try self.resolvePairing(params, approve: false)
        default:
            return nil
        }
    }

    // MARK: Channel pairing

    static let pairingAccounts: [JSONValue] = [
        ["channel": "telegram", "channelLabel": "Telegram", "accountId": "home", "accountLabel": "Home bot", "notifySupported": true],
        ["channel": "discord", "channelLabel": "Discord", "accountId": "family", "accountLabel": "Family server", "notifySupported": false],
    ]
    static let pairingTTL: TimeInterval = 60 * 60

    static func iso(_ date: Date) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    static func seedPairingRequests(now: Date = Date()) -> [JSONValue] {
        func request(_ id: String, account: Int, senderId: String, senderLabel: String, metadata: [String: JSONValue]?,
                     createdAgo: TimeInterval, lastSeenAgo: TimeInterval) -> JSONValue
        {
            let account = Self.pairingAccounts[account]
            let created = now.addingTimeInterval(-createdAgo)
            var row: [String: JSONValue] = [
                "requestId": .string(id), "channel": account["channel"] ?? .null, "channelLabel": account["channelLabel"] ?? .null,
                "accountId": account["accountId"] ?? .null, "accountLabel": account["accountLabel"] ?? .null,
                "senderId": .string(senderId), "senderLabel": .string(senderLabel),
                "createdAt": Self.iso(created), "lastSeenAt": Self.iso(now.addingTimeInterval(-lastSeenAgo)),
                "expiresAt": Self.iso(created.addingTimeInterval(Self.pairingTTL)),
                "notifySupported": account["notifySupported"] ?? false,
            ]
            if let metadata { row["metadata"] = .object(metadata) }
            return .object(row)
        }
        return [
            request("pr_demo_maya", account: 0, senderId: "5550142", senderLabel: "Telegram user id",
                    metadata: ["name": "Maya Chen", "username": "mayac", "languageCode": "en"],
                    createdAgo: 5 * 60, lastSeenAgo: 2 * 60),
            request("pr_demo_discord", account: 1, senderId: "418820017734812160", senderLabel: "Discord user id",
                    metadata: nil, createdAgo: 20 * 60, lastSeenAgo: 20 * 60),
            request("pr_demo_soon", account: 0, senderId: "5550199", senderLabel: "Telegram user id",
                    metadata: ["username": "night_owl"], createdAgo: Self.pairingTTL - 2 * 60, lastSeenAgo: Self.pairingTTL - 2 * 60),
        ]
    }

    func pairingList() -> JSONValue {
        let now = Date()
        let pending = self.pairingRequests.filter { PairingRequest($0).map { !$0.isExpired(at: now) } ?? false }
        return [
            "accounts": .array(Self.pairingAccounts),
            "requests": .array(pending),
            "commandOwnerConfigured": true,
            "limits": ["pendingPerAccount": 3, "ttlMs": .number(Self.pairingTTL * 1000)],
        ]
    }

    func resolvePairing(_ params: JSONValue, approve: Bool) throws -> JSONValue {
        guard let channel = params["channel"]?.string, let accountId = params["accountId"]?.string,
              let requestId = params["requestId"]?.string
        else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "channel, accountId and requestId are required", details: nil) }
        guard let account = Self.pairingAccounts.first(where: {
            $0["channel"]?.string == channel && $0["accountId"]?.string == accountId
        }) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST",
                                   message: "channel account does not use DM pairing: \(channel):\(accountId)", details: nil)
        }
        let now = Date()
        guard let index = self.pairingRequests.firstIndex(where: {
            $0["requestId"]?.string == requestId && $0["channel"]?.string == channel && $0["accountId"]?.string == accountId
        }), PairingRequest(self.pairingRequests[index])?.isExpired(at: now) == false else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "pending DM access request no longer exists", details: nil)
        }
        let senderId = self.pairingRequests[index]["senderId"] ?? .null
        self.pairingRequests.remove(at: index)
        guard approve else { return ["requestId": .string(requestId), "senderId": senderId] }
        let notification: String = switch params["notify"]?.bool {
        case true?: account["notifySupported"]?.bool == true ? "sent" : "unsupported"
        default: "not-requested"
        }
        return [
            "requestId": .string(requestId), "senderId": senderId, "notification": .string(notification),
            "commandOwnerBootstrap": params["bootstrapCommandOwner"]?.bool == true ? "already-configured" : "not-requested",
        ]
    }
}
