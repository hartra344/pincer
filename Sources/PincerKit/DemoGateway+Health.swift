import Foundation

/// Health, status, heartbeat, presence and restart.
extension DemoGateway {
    func handleHealth(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "health":
            return self.health()
        case "status":
            return ["ok": true, "version": "demo", "uptimeMs": .number((Date().timeIntervalSince(self.startedAt) * 1000).rounded()),
                    "sessions": ["count": JSONValue(self.sessions.count)]]
        case "last-heartbeat":
            return self.lastHeartbeat()
        case "system-presence":
            return .array(self.presence())
        case "gateway.restart.request":
            return self.requestRestart(params)
        default:
            return nil
        }
    }

    // MARK: Health and restart

    /// Discord is fine; Telegram lost its connection until a restart, so the demo starts out degraded.
    /// WhatsApp is enabled but not linked (not configured, so not a problem).
    func health() -> JSONValue {
        let now = Self.now()
        let nowMs = now.double ?? 0
        let channels: JSONValue = [
                "discord": [
                    "accountId": "default", "name": "Discord", "enabled": true, "configured": true, "running": true,
                    "connected": true, "restartPending": false, "reconnectAttempts": 0,
                    "lastConnectedAt": .number(self.startedAt.timeIntervalSince1970 * 1000), "lifecycle": "ready",
                    "lastInboundAt": .number(nowMs - 4 * 60_000), "lastOutboundAt": .number(nowMs - 3 * 60_000),
                ],
                "telegram": self.telegramRecovered ? [
                    "accountId": "default", "name": "Telegram", "enabled": true, "configured": true, "running": true,
                    "connected": true, "restartPending": false, "reconnectAttempts": 0,
                    "lastConnectedAt": .number(self.startedAt.timeIntervalSince1970 * 1000), "lifecycle": "ready",
                ] : [
                    "accountId": "default", "name": "Telegram", "enabled": true, "configured": true, "running": true,
                    "connected": false, "restartPending": false, "reconnectAttempts": 4,
                    "lastConnectedAt": .number(self.startedAt.timeIntervalSince1970 * 1000 + 5 * 60_000), "lifecycle": "recovering",
                    "lastError": "getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running",
                ],
                "whatsapp": self.whatsappAccount(),
            ]
        return [
            "ok": true, "ts": now, "durationMs": 42,
            "channels": .object((channels.object ?? [:]).reduce(into: [:]) { $0[$1.key] = self.applyChannelLifecycle($1.key, $1.value) }),
            "channelOrder": ["discord", "telegram", "whatsapp"],
            "channelLabels": ["discord": "Discord", "telegram": "Telegram", "whatsapp": "WhatsApp"],
            "heartbeatSeconds": 1800,
            "agents": .array(self.agents.map { agent in
                let id = agent["id"] ?? "main"
                return [
                    "agentId": id, "name": agent["name"] ?? id, "isDefault": .bool(id == "main"),
                    "heartbeat": ["enabled": .bool(id == "main"), "every": "30m", "everyMs": .number(1_800_000)],
                ]
            }),
            "sessions": ["count": JSONValue(self.sessions.count), "recent": []],
            "plugins": ["loaded": ["discord", "telegram", "whatsapp", "memory-core"], "errors": [], "unavailable": []],
            "deliveryQueues": ["failed": [],
                "ingressFailed": self.telegramRecovered ? [] : [["channelId": "telegram", "accountId": "default", "count": 2,
                                   "oldestFailedAt": .number(nowMs - 20 * 60_000)]],
                "ingressPressure": self.telegramRecovered ? [] : [["channelId": "telegram", "accountId": "default", "laneCount": 1,
                                     "pendingCount": 3, "claimedCount": 1, "blockedCount": 1,
                                     "oldestReceivedAt": .number(nowMs - 5 * 60_000)]],
            ],
            "contextEngines": ["quarantined": []],
            "modelPricing": ["state": "ok"],
            "configReload": ["hotReloadStatus": "active"],
        ]
    }

    func lastHeartbeat() -> JSONValue {
        [
            "ts": .number((Self.now().double ?? 0) - 7 * 60_000), "status": "ok-token", "to": "discord:#home",
            "channel": "discord", "durationMs": 3200, "indicatorType": "ok",
        ]
    }

    static var thisDeviceName: String {
        #if os(macOS)
        "Pincer on Mac"
        #else
        "Pincer on \(GatewayConnection.deviceFamily)"
        #endif
    }

    /// This device plus two others.
    func presence() -> [JSONValue] {
        let nowMs = Self.now().double ?? 0
        return [
            [
                "text": "Pincer", "host": .string(Self.thisDeviceName), "clientId": .string(GatewayConnection.clientId),
                "platform": .string(GatewayConnection.platform), "deviceFamily": .string(GatewayConnection.deviceFamily),
                "mode": "ui", "roles": ["operator"], "deviceId": .string(Self.deviceId), "ts": .number(nowMs),
                "onlineSince": .number(nowMs - 12 * 60_000), "lastActivityAt": .number(nowMs - 20_000),
            ],
            [
                "text": "Control UI", "host": "Studio iMac", "clientId": "openclaw-control-ui", "platform": "web",
                "deviceFamily": "Browser", "mode": "webchat", "roles": ["operator"], "ts": .number(nowMs - 60_000),
                "deviceId": "demo0device0000000000000000000000000000000000000000000000000002",
                "onlineSince": .number(nowMs - 3 * 3_600_000), "lastActivityAt": .number(nowMs - 9 * 60_000),
            ],
            [
                "text": "Node", "host": "kitchen-pi", "clientId": "node-host", "platform": "linux", "deviceFamily": "Raspberry Pi",
                "mode": "node", "roles": ["node"], "ts": .number(nowMs - 30_000),
                "deviceId": "demo0device0000000000000000000000000000000000000000000000000003",
                "onlineSince": .number(nowMs - 2 * 86_400_000), "lastActivityAt": .number(nowMs - 45 * 60_000),
            ],
        ]
    }

    /// Like `gateway.restart.request`: deferred while a reply is streaming (unless `skipDeferral`),
    /// then `shutdown`, the connection drops, and the next attach sees a fresh uptime.
    func requestRestart(_ params: JSONValue) -> JSONValue {
        let active = self.runs.count
        let skip = params["skipDeferral"]?.bool == true
        let counts: JSONValue = [
            "queueSize": 0, "pendingReplies": 0, "embeddedRuns": JSONValue(active), "cronRuns": 0,
            "backgroundExecSessions": 0, "rootRequests": 0, "activeTasks": 0, "totalActive": JSONValue(active),
        ]
        let blockers: [JSONValue] = active == 0 ? [] : [["message": .string("\(active) active agent run\(active == 1 ? "" : "s")")]]
        let preflight: JSONValue = [
            "safe": .bool(active == 0), "counts": counts, "blockers": .array(blockers),
            "summary": .string(active == 0 ? "restart safe now" : "restart deferred: \(active) active agent run\(active == 1 ? "" : "s")"),
        ]
        if self.restartTask != nil {
            // "Restart Now Anyway" escalates the pending restart.
            if skip { self.restartSkipsDeferral = true }
            return ["ok": true, "status": "coalesced", "preflight": preflight, "restart": ["coalesced": true]]
        }
        let deferred = active > 0 && !skip
        self.restartSkipsDeferral = false
        self.restartTask = Task { [weak self] in
            if deferred {
                while await self?.waitingForRuns == true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            await self?.shutdownForRestart(reason: params["reason"]?.text)
        }
        return ["ok": true, "status": .string(deferred ? "deferred" : "scheduled"), "preflight": preflight,
                "restart": ["coalesced": false, "delayMs": 0]]
    }

    var waitingForRuns: Bool { !self.runs.isEmpty && !self.restartSkipsDeferral }

    func shutdownForRestart(reason: String?) {
        self.restartTask = nil
        // A fresh start reconnects Telegram, so the restart visibly fixes the demo's one problem.
        self.telegramRecovered = true
        self.channelLifecycle.restart(at: Date().timeIntervalSince1970 * 1000)
        for id in self.runs.keys { self.abort(sessionKey: nil, runId: id) }
        self.restartingUntil = Date().addingTimeInterval(Double(Self.restartExpectedMs) / 1000)
        self.emit("shutdown", ["reason": .string(reason ?? "gateway restart"), "restartExpectedMs": JSONValue(Self.restartExpectedMs)])
        self.sink = nil
    }
}
