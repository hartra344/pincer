import Foundation

/// Channel lifecycle in the demo (`channels.start` / `channels.stop` / `channels.logout`), shaped like
/// upstream's handlers: stopping marks the account stopped, starting brings it back (and a fresh start
/// reconnects Telegram, the demo's one degraded channel), logging out clears WhatsApp's link and
/// Telegram's token; Discord doesn't support logout. Starting an account that is already running is
/// left to its task (`retry` / `task-owned`), so Telegram needs Reconnect (stop, then start).
struct DemoChannelsState {
    /// Channels whose default account was stopped with `channels.stop`.
    var stopped: Set<String> = []
    /// Channels logged out with `channels.logout` (other than WhatsApp, whose link is `setup.whatsappLinked`).
    var loggedOut: Set<String> = []
    var stoppedAt: [String: Double] = [:]
    var startedAt: [String: Double] = [:]

    /// A Gateway restart starts every configured account again; logged-out ones stay down.
    mutating func restart(at nowMs: Double) {
        for channel in self.stopped.subtracting(self.loggedOut) { self.startedAt[channel] = nowMs }
        self.stopped.formIntersection(self.loggedOut)
    }
}

extension DemoGateway {
    static let channelLifecycleMethods = ["channels.start", "channels.stop", "channels.logout"]
    private static let lifecycleChannels: Set<String> = ["discord", "telegram", "whatsapp"]
    private static let logoutChannels: Set<String> = ["telegram", "whatsapp"]

    /// Nil when `method` isn't a lifecycle method.
    func handleChannelLifecycle(_ method: String, _ params: JSONValue) async throws -> JSONValue? {
        guard Self.channelLifecycleMethods.contains(method) else { return nil }
        try Self.lifecycleParams(params, method)
        let raw = params["channel"]?.text ?? ""
        let channel = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.lifecycleChannels.contains(channel) else {
            throw Self.lifecycleInvalid("invalid \(method) channel")
        }
        let accountId = params["accountId"]?.text ?? "default"
        let nowMs = Self.now().double ?? 0
        switch method {
        case "channels.stop":
            self.channelLifecycle.stopped.insert(channel)
            self.channelLifecycle.stoppedAt[channel] = nowMs
            self.emitHealth()
            return ["channel": .string(channel), "accountId": .string(accountId), "stopped": true]
        case "channels.start":
            if channel == "whatsapp", !self.setup.whatsappLinked {
                return ["channel": "whatsapp", "accountId": .string(accountId), "started": false,
                        "outcome": ["status": "skipped", "reason": "unlinked"]]
            }
            if self.channelLifecycle.loggedOut.contains(channel) {
                return ["channel": .string(channel), "accountId": .string(accountId), "started": false,
                        "outcome": ["status": "skipped", "reason": "unconfigured"]]
            }
            if !self.channelLifecycle.stopped.contains(channel) {
                // Already running: the Gateway leaves it to the account's task.
                return ["channel": .string(channel), "accountId": .string(accountId), "started": true,
                        "outcome": ["status": "retry", "reason": "task-owned"]]
            }
            self.channelLifecycle.stopped.remove(channel)
            self.channelLifecycle.startedAt[channel] = nowMs
            if channel == "telegram" { self.telegramRecovered = true }
            self.emitHealth()
            return ["channel": .string(channel), "accountId": .string(accountId), "started": true,
                    "outcome": ["status": "handed-off"]]
        default:
            guard Self.logoutChannels.contains(channel) else {
                throw Self.lifecycleInvalid("channel \(channel) does not support logout")
            }
            let cleared: Bool
            if channel == "whatsapp" {
                cleared = self.setup.whatsappLinked
                self.setup.whatsappLinked = false
                self.setup.whatsappLinkedAt = nil
                self.setup.login = nil
                // Unlinked already reads as not running, and linking again starts it.
                self.channelLifecycle.stopped.remove(channel)
            } else {
                cleared = !self.channelLifecycle.loggedOut.contains(channel)
                self.channelLifecycle.loggedOut.insert(channel)
                self.channelLifecycle.stopped.insert(channel)
            }
            self.emitHealth()
            return ["channel": .string(channel), "accountId": .string(accountId), "cleared": .bool(cleared),
                    "loggedOut": .bool(cleared)]
        }
    }

    /// A `health` channel entry after the demo's lifecycle changes.
    func applyChannelLifecycle(_ channel: String, _ entry: JSONValue) -> JSONValue {
        guard var object = entry.object else { return entry }
        if let at = self.channelLifecycle.startedAt[channel] { object["lastStartAt"] = .number(at) }
        if self.channelLifecycle.loggedOut.contains(channel) {
            object["configured"] = false
            object["lastError"] = nil
        }
        if self.channelLifecycle.stopped.contains(channel) {
            object["running"] = false
            object["connected"] = false
            object["lifecycle"] = "stopped"
            object["lastError"] = nil
            object["reconnectAttempts"] = 0
            if let at = self.channelLifecycle.stoppedAt[channel] { object["lastStopAt"] = .number(at) }
        }
        return .object(object)
    }

    private static func lifecycleInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }

    private static func lifecycleParams(_ params: JSONValue, _ method: String) throws {
        guard let object = params.object else { throw Self.lifecycleInvalid("invalid \(method) params: must be object") }
        if let extra = object.keys.sorted().first(where: { $0 != "channel" && $0 != "accountId" }) {
            throw Self.lifecycleInvalid("invalid \(method) params: must NOT have additional properties (\(extra))")
        }
        guard object["channel"]?.text?.isEmpty == false else {
            throw Self.lifecycleInvalid("invalid \(method) params: must have required property 'channel'")
        }
    }
}
