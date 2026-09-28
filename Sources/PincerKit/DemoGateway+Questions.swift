import Foundation

/// Agent questions.
extension DemoGateway {
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
        self.questions[id] = record
        self.questionOrder.append(id)
        self.emit("question.requested", record)

        while self.questions[id]?["status"]?.string == "pending" {
            guard await self.pause(runId, milliseconds: 100) else {
                self.settleQuestion(id, status: "cancelled", answers: nil)
                return nil
            }
            if let expires = record["expiresAtMs"]?.double, (Self.now().double ?? 0) >= expires {
                self.settleQuestion(id, status: "expired", answers: nil)
            }
        }
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
        self.settleQuestion(id, status: "answered", answers: ["answers": answers ?? [:]])
        return ["status": "answered", "answers": ["answers": answers ?? [:]]]
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
