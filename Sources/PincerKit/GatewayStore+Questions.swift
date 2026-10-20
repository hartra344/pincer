import Foundation
import Observation

extension GatewayStore {
    // MARK: Questions

    /// Pending questions for a chat, dropping any that have expired.
    public func pendingQuestions(for sessionKey: String?, at date: Date = Date()) -> [QuestionPrompt] {
        self.questions.filter { $0.isAnswerable(at: date) && $0.belongs(to: sessionKey) }
    }

    func refreshQuestions() async {
        // Older Gateways and connections without `operator.questions` just have none.
        guard let result = try? await self.connection.request("question.list", [:]) else { return }
        let items = result["questions"]?.array ?? result.array ?? []
        self.questions = items.compactMap(QuestionPrompt.init).filter { $0.isAnswerable() }
    }

    func upsertQuestion(_ prompt: QuestionPrompt) {
        guard prompt.isAnswerable() else {
            self.questions.removeAll { $0.id == prompt.id }
            return
        }
        if let index = self.questions.firstIndex(where: { $0.id == prompt.id }) {
            self.questions[index] = prompt
        } else {
            self.questions.append(prompt)
        }
    }

    /// Sends the answers. Returns an error message to show on the card, or nil once it's answered.
    public func answerQuestion(_ prompt: QuestionPrompt, answers: [String: [String]]) async -> String? {
        let params: JSONValue = [
            "id": .string(prompt.id),
            "answers": ["answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) })],
        ]
        return await self.resolveQuestion(prompt, params)
    }

    /// Skips the prompt; the agent is told the user declined to answer.
    public func skipQuestion(_ prompt: QuestionPrompt) async -> String? {
        await self.resolveQuestion(prompt, prompt.cancelPayload)
    }

    private func resolveQuestion(_ prompt: QuestionPrompt, _ params: JSONValue) async -> String? {
        do {
            _ = try await self.connection.request("question.resolve", params)
            self.questions.removeAll { $0.id == prompt.id }
            return nil
        } catch {
            if case let GatewayError.rpc(_, message, details) = error {
                // Already settled elsewhere (another client, a channel button, expiry) or the agent stopped.
                let reason = details?["reason"]?.string
                if ["QUESTION_NOT_FOUND", "QUESTION_ALREADY_TERMINAL", "QUESTION_REQUESTER_INACTIVE"].contains(reason)
                    || message.contains("was not found")
                {
                    self.questions.removeAll { $0.id == prompt.id }
                    return nil
                }
                if details?["missingScope"]?.string == GatewayConnection.questionsScope
                    || message.contains(GatewayConnection.questionsScope)
                {
                    return "This device isn't allowed to answer questions yet. Approve its pending request on the Gateway host."
                }
                return message
            }
            return error.localizedDescription
        }
    }
}
