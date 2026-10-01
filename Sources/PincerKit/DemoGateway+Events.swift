import Foundation

/// Event emission and transcript helpers.
extension DemoGateway {
    // MARK: Events

    func emitHealth() {
        self.emit("health", self.health())
    }

    func replaySeededRuns() {
        for event in Self.seededRunEvents() { self.emit("agent", event) }
        self.seededStreamTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveSubagentStepInterval)
                guard let self, await self.streamSeededStep(step) else { return }
                step += 1
            }
        }
    }

    func streamSeededStep(_ step: Int) -> Bool {
        guard !Task.isCancelled, self.seededRunningRuns[Self.seededRunningSubagentRunId] != nil else { return false }
        let next = Self.liveSubagentStep(step, seq: self.seededRunningSeq)
        self.seededRunningSeq = next.seq
        for event in next.events { self.emit("agent", event) }
        return true
    }

    func emit(_ name: String, _ payload: JSONValue) {
        self.eventSeq += 1
        self.sink?(GatewayEvent(name: name, payload: payload, seq: self.eventSeq))
    }

    func chat(_ runId: String, _ fields: Row) {
        guard var run = self.runs[runId] else { return }
        run.seq += 1
        self.runs[runId] = run
        var payload = fields
        payload["runId"] = .string(runId)
        payload["sessionKey"] = .string(run.sessionKey)
        payload["seq"] = JSONValue(run.seq)
        self.emit("chat", .object(payload))
    }

    func agentEvent(_ runId: String, stream: String, _ data: JSONValue) {
        guard var run = self.runs[runId] else { return }
        run.seq += 1
        self.runs[runId] = run
        self.emit("agent", ["runId": .string(runId), "sessionKey": .string(run.sessionKey), "seq": JSONValue(run.seq),
                            "stream": .string(stream), "data": data])
    }

    func append(_ key: String, _ message: JSONValue) {
        self.transcripts[key, default: []].append(message)
        guard self.messageSubscriptions[key] != nil else { return }
        self.emit("session.message", [
            "sessionKey": .string(key),
            "message": message,
            "messageId": message["__openclaw"]?["id"] ?? .null,
            "messageSeq": JSONValue(self.transcripts[key]?.count ?? 0),
            "hasActiveRun": true,
        ])
    }

    func updateRow(_ key: String, reason: String, _ change: (inout Row) -> Void) {
        guard var row = self.sessions[key] else { return }
        change(&row)
        self.touch(&row)
        self.sessions[key] = row
        self.sessionChanged(key, reason: reason)
    }

    func touch(_ row: inout Row) {
        row["updatedAt"] = Self.now()
        row["lastActivityAt"] = Self.now()
    }

    /// Drops a deleted agent's chats, telling subscribers like the Gateway does.
    func removeSessions(ofAgent agentId: String) {
        let keys = self.sessions.filter { $0.value["agentId"]?.string == agentId || $0.key.hasPrefix("agent:\(agentId):") }.keys
        for key in keys {
            self.sessions[key] = nil
            self.transcripts[key] = nil
            if self.sessionsSubscribed { self.emit("sessions.changed", ["sessionKey": .string(key), "reason": "delete"]) }
        }
    }

    func sessionChanged(_ key: String, reason: String) {
        guard self.sessionsSubscribed, let row = self.sessions[key] else { return }
        self.emit("sessions.changed", ["sessionKey": .string(key), "reason": .string(reason), "session": .object(row)])
    }

    func rowModel(_ key: String) -> (provider: String, model: String) {
        let row = self.sessions[key]
        return (row?["modelProvider"]?.string ?? Self.defaultModel.provider, row?["model"]?.string ?? Self.defaultModel.model)
    }
}
