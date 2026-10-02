import Foundation
import Testing
@testable import PincerKit

@Suite("Questions")
struct QuestionsTests {
    @Test func decodesSecureFormPrompt() {
        let prompt = QuestionPrompt(Fixtures.json(#"""
        {
          "id": "ask_secure",
          "kind": "secure_form",
          "requestId": "secure_req_123",
          "origin": "mail.google.com",
          "fields": [
            {"fieldId": "identifier", "role": "username"},
            {"fieldId": "password", "role": "password"},
            {"fieldId": "otp", "role": "otp"},
            {"fieldId": "recovery", "role": "email"},
            {"fieldId": "custom", "role": "federated-id"}
          ],
          "agentId": "main",
          "sessionKey": "agent:main:main",
          "runId": "run_123",
          "expiresAtMs": 1700000000000,
          "status": "pending"
        }
        """#))

        #expect(prompt?.id == "ask_secure")
        #expect(prompt?.kind == .secureForm)
        #expect(prompt?.questions.isEmpty == true)
        #expect(prompt?.promptText == "Secure sign-in for mail.google.com")
        #expect(prompt?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))

        let secureForm = prompt?.secureForm
        #expect(secureForm?.requestId == "secure_req_123")
        #expect(secureForm?.origin == "mail.google.com")
        #expect(secureForm?.fields.map(\.fieldId) == ["identifier", "password", "otp", "recovery", "custom"])
        #expect(secureForm?.fields.map(\.role) == [.username, .password, .otp, .email, .other("federated-id")])
    }

    @Test func encodesSecureFormAnswers() throws {
        let prompt = QuestionPrompt(Fixtures.json(#"""
        {
          "id": "ask_secure",
          "kind": "secure_form",
          "requestId": "secure_req_123",
          "origin": "mail.google.com",
          "fields": [
            {"fieldId": "identifier", "role": "username"},
            {"fieldId": "password", "role": "password"},
            {"fieldId": "otp", "role": "otp"}
          ],
          "status": "pending"
        }
        """#))!
        let secureForm = try #require(prompt.secureForm)
        var draft = SecureFormDraft()
        draft.setText("user@example.com", for: secureForm.fields[0])
        draft.setText("correct horse battery staple", for: secureForm.fields[1])
        #expect(draft.answers(for: prompt) == nil)
        draft.setText("123456", for: secureForm.fields[2])

        #expect(draft.answers(for: prompt) == [
            "identifier": "user@example.com",
            "password": "correct horse battery staple",
            "otp": "123456",
        ])
        #expect(draft.resolvePayload(for: prompt) == [
            "id": "ask_secure",
            "answers": [
                "requestId": "secure_req_123",
                "answers": [
                    "identifier": "user@example.com",
                    "password": "correct horse battery staple",
                    "otp": "123456",
                ],
            ],
        ])
        #expect(prompt.cancelPayload == ["id": "ask_secure", "cancel": true])
    }

    @Test func expiryUsesExpiresAtForSecureForm() {
        let prompt = QuestionPrompt(Fixtures.json(#"""
        {
          "id": "ask_secure",
          "kind": "secure_form",
          "requestId": "secure_req_123",
          "origin": "mail.google.com",
          "fields": [{"fieldId": "password", "role": "password"}],
          "expiresAtMs": 2000,
          "status": "pending"
        }
        """#))!
        #expect(!prompt.isExpired(at: Date(timeIntervalSince1970: 1.999)))
        #expect(prompt.isExpired(at: Date(timeIntervalSince1970: 2.0)))
    }

    @Test func secureFormOriginOnlyComesFromTopLevelPayload() throws {
        let prompt = try #require(QuestionPrompt(Fixtures.json(#"""
        {
          "id": "ask_secure",
          "kind": "secure_form",
          "requestId": "secure_req_123",
          "origin": "mail.google.com",
          "fields": [
            {"fieldId": "identifier", "role": "username", "origin": "evil.example"}
          ],
          "status": "pending"
        }
        """#)))
        let secureForm = try #require(prompt.secureForm)
        #expect(secureForm.origin == "mail.google.com")
        #expect(secureForm.fields.count == 1)

        let payload = try #require(secureForm.answersPayload(["identifier": "user@example.com"]))
        let text = try String(decoding: payload.encoded(), as: UTF8.self)
        #expect(text.contains(#""requestId":"secure_req_123""#))
        #expect(!text.contains("mail.google.com"))
        #expect(!text.contains("evil.example"))
        #expect(!text.contains(#""origin""#))
    }
}
