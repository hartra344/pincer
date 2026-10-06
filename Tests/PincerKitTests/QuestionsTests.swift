import Foundation
import Testing
@testable import PincerKit

@Suite("Questions")
struct QuestionsTests {
    /// The record upstream's `secrets` tool sends through `question.request` (secrets-tool.ts).
    static let secretRecord = #"""
    {
      "id": "ask_secret",
      "questions": [{
        "questionId": "secret_value",
        "header": "API key",
        "question": "Provide the secret for STRIPE_API_KEY.",
        "options": [],
        "presentation": "form",
        "isSecret": true,
        "secretStore": {"name": "STRIPE_API_KEY", "kind": "secret", "allowedHosts": ["api.stripe.com"]}
      }],
      "sessionKey": "agent:main:main",
      "createdAtMs": 1760000000000,
      "expiresAtMs": 1760000900000,
      "status": "pending"
    }
    """#

    @Test func decodesSecretStoreQuestion() throws {
        let prompt = try #require(QuestionPrompt(Fixtures.json(Self.secretRecord)))
        let question = try #require(prompt.questions.first)
        #expect(question.isSecret)
        #expect(question.secretStoreName == "STRIPE_API_KEY")
        #expect(question.allowsFreeText)
        #expect(prompt.promptText == "Provide the secret for STRIPE_API_KEY.")
    }

    /// #924: upstream has no `kind: "secure_form"`; a record without questions isn't a prompt, even with a `requestId`.
    @Test func ignoresInventedSecureFormRecords() {
        let invented = QuestionPrompt(Fixtures.json(#"""
        {"id": "ask_secure", "kind": "secure_form", "requestId": "secure_req_123", "origin": "mail.google.com",
         "fields": [{"fieldId": "password", "role": "password"}], "status": "pending"}
        """#))
        #expect(invented == nil)
        let bareRequestId = QuestionPrompt(Fixtures.json(#"{"id": "ask_x", "requestId": "r1", "status": "pending"}"#))
        #expect(bareRequestId == nil)
    }

    @Test func secretAnswerIsSentExactlyAsTyped() throws {
        let prompt = try #require(QuestionPrompt(Fixtures.json(Self.secretRecord)))
        var draft = QuestionDraft()
        draft.setText(" sk_test_123 \n", for: prompt.questions[0])
        #expect(draft.answers(for: prompt) == ["secret_value": [" sk_test_123 \n"]])
    }

    /// Like upstream, the demo writes a store-bound answer to `secrets.store` and only the `"stored"` marker goes on.
    @Test func demoStoresSecretAnswersAndFansOutOnlyTheMarker() async throws {
        let demo = DemoGateway()
        await demo.publishQuestion("ask_secret", Fixtures.json(Self.secretRecord))
        do {
            _ = try await demo.handle("question.resolve", ["id": "ask_secret", "answers": ["answers": ["secret_value": ["a", "b"]]]])
            Issue.record("two values were accepted for a store-bound question")
        } catch GatewayError.rpc(_, _, let details) {
            #expect(details?["reason"]?.string == "QUESTION_INVALID_ANSWER")
        }
        let result = try await demo.handle("question.resolve",
                                           ["id": "ask_secret", "answers": ["answers": ["secret_value": [" sk_test_123 "]]]])
        #expect(result == ["status": "answered", "answers": ["answers": ["secret_value": ["stored"]]]])
        #expect(await demo.voice.secrets["STRIPE_API_KEY"]?.value == " sk_test_123 ")
        #expect(await demo.voice.secrets["STRIPE_API_KEY"]?.allowedHosts == ["api.stripe.com"])
        let record = try #require(await demo.questions["ask_secret"])
        #expect(!String(decoding: try record.encoded(), as: UTF8.self).contains("sk_test_123"))
    }
}
