import Foundation

/// Agent questions.
extension DemoGateway {
    func publishQuestion(_ id: String, _ record: JSONValue) {
        self.questions[id] = record
        self.questionOrder.append(id)
        self.emit("question.requested", record)
    }

    func waitForQuestion(_ id: String, runId: String, expiresAtMs: Double) async -> Bool {
        while self.questions[id]?["status"]?.string == "pending" {
            guard await self.pause(runId, milliseconds: 100) else {
                self.settleQuestion(id, status: "cancelled", answers: nil)
                return false
            }
            if (Self.now().double ?? 0) >= expiresAtMs {
                self.settleQuestion(id, status: "expired", answers: nil)
            }
        }
        return true
    }

    func handleQuestions(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "question.list":
            return ["questions": .array(self.questionOrder.compactMap { self.questions[$0] }
                    .filter { $0["status"]?.string == "pending" })]
        case "question.resolve":
            return try self.resolveQuestion(params)
        default:
            return nil
        }
    }

    /// Asks an `ask_user` question and waits for it to be answered, skipped or to expire.
    /// Returns the reply text, or nil if the run was stopped.
    func simulateQuestion(runId: String, key: String, model: (provider: String, model: String)) async -> String? {
        let callId = Self.shortId("call_")
        let options: [JSONValue] = [
            ["label": "Disconnect Discord from OpenClaw",
             "description": "Remove the Discord channel integration/config; the server itself stays intact"],
            ["label": "Delete one channel in the Discord server", "description": "e.g. #coworking or #gyms — tell me which"],
            ["label": "Stop watching Discord channels here", "description": "Only stop this chat from ambiently watching them"],
        ]
        let args: JSONValue = ["questions": [["id": "discord_remove", "header": "Discord",
                                              "question": "What do you want removed?", "options": .array(options)]]]
        self.agentEvent(runId, stream: "tool",
                        ["phase": "start", "name": "ask_user", "toolCallId": .string(callId), "args": args])
        let id = Self.shortId("ask_")
        let record: JSONValue = [
            "id": .string(id),
            "questions": [["questionId": "discord_remove", "header": "Discord", "question": "What do you want removed?",
                           "options": .array(options), "isOther": true]],
            "agentId": self.sessions[key]?["agentId"] ?? "main",
            "sessionKey": .string(key),
            "runId": .string(runId),
            "createdAtMs": Self.now(),
            "expiresAtMs": .number((Self.now().double ?? 0) + 900_000),
            "status": "pending",
        ]
        self.publishQuestion(id, record)
        guard await self.waitForQuestion(id, runId: runId, expiresAtMs: record["expiresAtMs"]?.double ?? 0) else { return nil }
        let status = self.questions[id]?["status"]?.string ?? "cancelled"
        let picked = self.questions[id]?["answers"]?["answers"]?["discord_remove"]?.array?.compactMap(\.string) ?? []
        let output = status == "answered" ? "User answered: \(picked.joined(separator: ", "))" : "User \(status == "expired" ? "didn't answer in time" : "skipped the question")"
        self.agentEvent(runId, stream: "tool",
                        ["phase": "result", "name": "ask_user", "toolCallId": .string(callId), "isError": false,
                         "result": .string(output)])
        self.append(key, Self.message("assistant", [Self.toolCall(callId, "ask_user", args)], runId: runId, model: model))
        self.append(key, Self.message("toolResult", [Self.text(output)], runId: runId,
                                      extra: ["toolCallId": .string(callId), "toolName": "ask_user", "isError": false]))
        return status == "answered"
            ? "Got it — \(picked.joined(separator: ", ")). (This is the demo, so nothing was actually removed.)"
            : "No problem, I'll leave Discord as it is."
    }

    /// Requests an API key the way upstream's `secrets` tool does: one `isSecret` question bound to the secret store.
    /// Answering saves the value to `secrets.store`; only the `"stored"` marker reaches the record, events and transcript.
    func simulateSecretQuestion(runId: String, key: String, model: (provider: String, model: String)) async -> String? {
        let callId = Self.shortId("call_")
        let name = "STRIPE_API_KEY"
        let reason = "Needed to reconcile this month's Stripe payouts."
        let args: JSONValue = ["action": "request", "name": .string(name), "allowedHosts": ["api.stripe.com"], "reason": .string(reason)]
        self.agentEvent(runId, stream: "tool",
                        ["phase": "start", "name": "secrets", "toolCallId": .string(callId), "args": args])
        let id = Self.shortId("ask_")
        let expiresAtMs = (Self.now().double ?? 0) + 900_000
        let record: JSONValue = [
            "id": .string(id),
            "questions": [["questionId": "secret_value", "header": "API key", "question": .string("Provide the secret for \(name)."),
                           "options": [], "isSecret": true,
                           "secretStore": ["name": .string(name), "kind": "secret", "allowedHosts": ["api.stripe.com"],
                                           "reason": .string(reason)]]],
            "agentId": self.sessions[key]?["agentId"] ?? "main",
            "sessionKey": .string(key),
            "runId": .string(runId),
            "createdAtMs": Self.now(),
            "expiresAtMs": .number(expiresAtMs),
            "status": "pending",
        ]
        self.publishQuestion(id, record)
        guard await self.waitForQuestion(id, runId: runId, expiresAtMs: expiresAtMs) else { return nil }
        let stored = self.questions[id]?["status"]?.string == "answered"
        let output = stored
            ? "Stored; value hidden. Use the returned ref for config SecretRefs.\n\n{\"status\":\"stored\",\"name\":\"\(name)\",\"kind\":\"secret\",\"ref\":{\"source\":\"store\",\"provider\":\"default\",\"id\":\"\(name)\"}}"
            : "No credential arrived; proceed with best judgment.\n\n{\"status\":\"no_answer\"}"
        self.agentEvent(runId, stream: "tool",
                        ["phase": "result", "name": "secrets", "toolCallId": .string(callId), "isError": false,
                         "result": .string(output)])
        self.append(key, Self.message("assistant", [Self.toolCall(callId, "secrets", args)], runId: runId, model: model))
        self.append(key, Self.message("toolResult", [Self.text(output)], runId: runId,
                                      extra: ["toolCallId": .string(callId), "toolName": "secrets", "isError": false]))
        return stored
            ? "Thanks — \(name) is in the Gateway's secret store. I'll reference it by name and never see the value."
            : "No problem, I'll skip the Stripe reconciliation for now."
    }

    func resolveQuestion(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.string, let record = self.questions[id] else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "question was not found",
                                   details: ["reason": "QUESTION_NOT_FOUND"])
        }
        guard record["status"]?.string == "pending" else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "question is already resolved",
                                   details: ["reason": "QUESTION_ALREADY_TERMINAL"])
        }
        if params["cancel"]?.bool == true {
            self.settleQuestion(id, status: "cancelled", answers: nil)
            return ["status": "cancelled"]
        }
        let answers = params["answers"]?["answers"]
        let ids = (record["questions"]?.array ?? []).compactMap { $0["questionId"]?.string }
        guard ids.allSatisfy({ !(answers?[$0]?.array?.compactMap(\.string) ?? []).isEmpty }) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "every question needs an answer",
                                   details: ["reason": "QUESTION_INVALID_ANSWER"])
        }
        // Like upstream, a store-bound answer is written to the secret store and only the "stored" marker goes on.
        if let secret = record["questions"]?.array?.first, let name = secret["secretStore"]?["name"]?.string,
           let questionId = secret["questionId"]?.string
        {
            let values = answers?[questionId]?.array?.compactMap(\.string) ?? []
            guard values.count == 1, let value = values.first, !value.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "question '\(questionId)' requires exactly one secret value",
                                       details: ["reason": "QUESTION_INVALID_ANSWER"])
            }
            let now = Self.now().double ?? 0
            let hosts = (secret["secretStore"]?["allowedHosts"]?.array ?? []).compactMap(\.string)
            self.voice.secrets[name] = DemoVoiceState.SecretEntry(
                kind: secret["secretStore"]?["kind"]?.string ?? "secret", value: value, allowedHosts: hosts.sorted(),
                createdAtMs: self.voice.secrets[name]?.createdAtMs ?? now, updatedAtMs: now)
            let marker: JSONValue = ["answers": [questionId: ["stored"]]]
            self.settleQuestion(id, status: "answered", answers: marker)
            return ["status": "answered", "answers": marker]
        }
        let resolved: JSONValue = ["answers": answers ?? [:]]
        self.settleQuestion(id, status: "answered", answers: resolved)
        return ["status": "answered", "answers": resolved]
    }

    func settleQuestion(_ id: String, status: String, answers: JSONValue?) {
        guard case var .object(record)? = self.questions[id], record["status"]?.string == "pending" else { return }
        record["status"] = .string(status)
        if let answers { record["answers"] = answers }
        self.questions[id] = .object(record)
        var event: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        if let answers { event["answers"] = answers }
        self.emit("question.resolved", .object(event))
    }
}
