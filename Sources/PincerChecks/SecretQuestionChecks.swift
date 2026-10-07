import Foundation
import PincerKit

/// Upstream's `secrets` tool asks one `isSecret` question bound to the secret store (#924). Sends a canary through
/// the question card's path and checks it never lands in the transcript, its cache, Read Aloud or the Gateway log.
@MainActor
func checkSecretQuestion(_ gateway: GatewayStore, chat: ChatStore, key: String, label: String) async {
    await chat.send("save my stripe secret")
    let asked = await waitFor("\(label) secret question") { !gateway.pendingQuestions(for: key).isEmpty }
    check(asked, "\(label): secret-store question surfaced")
    guard let prompt = gateway.pendingQuestions(for: key).first, let question = prompt.questions.first else {
        check(false, "\(label): secret-store prompt available")
        return
    }
    check(question.isSecret && question.secretStoreName == "STRIPE_API_KEY" && question.options.isEmpty && question.allowsFreeText,
          "\(label): secret question is masked free text bound to STRIPE_API_KEY")
    let canary = " sk_test_pincer-canary "
    var draft = QuestionDraft()
    draft.setText(canary, for: question)
    check(draft.answers(for: prompt) == [question.questionId: [canary]], "\(label): secret answer sent exactly as typed")
    let error = await gateway.answerQuestion(prompt, answers: draft.answers(for: prompt) ?? [:])
    check(error == nil && gateway.pendingQuestions(for: key).isEmpty, "\(label): secret question answered (\(error ?? "ok"))")
    let replied = await waitFor("\(label) secret reply", timeout: 20) {
        if case let .assistant(turn)? = chat.entries.last { return !chat.isRunning && turn.body.contains("is in the Gateway's secret store") }
        return false
    }
    check(replied, "\(label): agent continues after the secret is stored")

    let needle = "pincer-canary"
    let cached = (try? JSONEncoder().encode(chat.items)).map { String(decoding: $0, as: UTF8.self) } ?? needle
    check(!cached.contains(needle), "\(label): secret never reaches the transcript or its cache")
    let tools = chat.entries.compactMap { entry -> ToolActivity? in
        if case let .assistant(turn) = entry { return turn.tools.first { $0.name == "secrets" } }
        return nil
    }
    check(!tools.isEmpty && !tools.contains { ($0.arguments ?? "").contains(needle) || ($0.result ?? "").contains(needle) },
          "\(label): secrets tool card shows the stored marker, never the value")
    check(!chat.items.compactMap(SpeechText.speakableText(for:)).contains { $0.contains(needle) },
          "\(label): Read Aloud never speaks the secret")
    let logs = gateway.gatewayLogs
    await logs.poll()
    check(!logs.entries.contains { $0.line.message.contains(needle) || $0.line.raw.contains(needle) }, "\(label): secret never reaches the Gateway log")
}
