import Foundation
import Testing
@testable import PincerKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTrip() throws {
        let value: JSONValue = [
            "null": nil, "bool": true, "int": 42, "negative": -7, "double": 1.5, "string": "héllo/“quoted”",
            "array": [1, "two", false, nil], "object": ["nested": ["deep": 3]],
            "big": .number(1_700_000_000_123),
        ]
        let data = try value.encoded()
        #expect(try JSONValue.decode(data) == value)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"int\":42") && !text.contains("42.0"))
        #expect(text.contains("\"big\":1700000000123"))
        #expect(text.contains("héllo/")) // slashes aren't escaped
    }

    @Test func accessors() {
        let value = Fixtures.json(#"{"n":3,"s":"  x ","e":"   ","f":2.5,"ns":"12","arr":[1]}"#)
        #expect(value["n"]?.int == 3 && value["n"]?.int64 == 3 && value["n"]?.string == nil)
        #expect(value["s"]?.text == "x" && value["s"]?.string == "  x ")
        #expect(value["e"]?.text == nil)
        #expect(value["f"]?.int64 == nil && value["f"]?.double == 2.5)
        #expect(value["ns"]?.int == 12)
        #expect(value["arr"]?[0]?.int == 1 && absent(value["arr"]?[1]))
        #expect(value.contains("n") && !value.contains("missing"))
        #expect(value["missing"]?.int == nil)
        #expect(JSONValue.null.isNull && JSONValue(nil as String?) == .null)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try JSONValue.decode(Data("{not json".utf8)) }
    }
}

@Suite("Inbound frames")
struct InboundFrameTests {
    func frame(_ text: String) -> GatewayConnection.InboundFrame? {
        GatewayConnection.inboundFrame(Data(text.utf8))
    }

    @Test func okResponse() {
        guard case let .response(id, result)? = self.frame(#"{"type":"res","id":"r1","ok":true,"payload":{"a":1}}"#),
              case let .success(payload) = result
        else { Issue.record("expected ok response"); return }
        #expect(id == "r1" && payload == ["a": 1])

        guard case let .response(_, empty)? = self.frame(#"{"type":"res","id":"r2","ok":true}"#), case .success(.null) = empty
        else { Issue.record("missing payload should be null"); return }
    }

    @Test func errorResponse() {
        let text = #"{"type":"res","id":"r1","ok":false,"error":{"code":"UNAUTHORIZED","message":"nope","details":{"code":"AUTH_TOKEN_INVALID"}}}"#
        guard case let .response(id, .failure(error))? = self.frame(text) else { Issue.record("expected error"); return }
        #expect(id == "r1")
        #expect(error == .rpc(code: "UNAUTHORIZED", message: "nope", details: ["code": "AUTH_TOKEN_INVALID"]))
        #expect(error.detailCode == "AUTH_TOKEN_INVALID")
        #expect(error.localizedDescription == "nope [AUTH_TOKEN_INVALID]")

        guard case let .response(_, .failure(bare))? = self.frame(#"{"type":"res","id":"r2","ok":false}"#) else {
            Issue.record("expected error"); return
        }
        #expect(bare == .rpc(code: "ERROR", message: "Request failed", details: nil))
    }

    @Test func events() {
        guard case let .event(event)? = self.frame(#"{"type":"event","event":"chat","seq":7,"payload":{"x":true}}"#) else {
            Issue.record("expected event"); return
        }
        #expect(event.name == "chat" && event.seq == 7 && event.payload == ["x": true])

        guard case let .event(noSeq)? = self.frame(#"{"type":"event","event":"agent"}"#) else { Issue.record("event"); return }
        #expect(noSeq.seq == nil && noSeq.payload == .null)

        guard case .tick? = self.frame(#"{"type":"event","event":"tick","payload":{"ts":1}}"#) else { Issue.record("tick"); return }
        guard case .shutdown? = self.frame(#"{"type":"event","event":"shutdown"}"#) else { Issue.record("shutdown"); return }
        guard case let .challenge(nonce, ts)? = self.frame(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n","ts":9}}"#)
        else { Issue.record("challenge"); return }
        #expect(nonce == "n" && ts == 9)
    }

    @Test func ignored() {
        #expect(self.frame("not json") == nil)
        #expect(self.frame(#"{"id":"r1","ok":true}"#) == nil)
        #expect(self.frame(#"{"type":"req","id":"r1","method":"x"}"#) == nil)
        #expect(self.frame(#"{"type":"res","ok":true}"#) == nil)
        #expect(self.frame(#"{"type":"event","payload":{}}"#) == nil)
        #expect(self.frame(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n","ts":-5}}"#) == nil)
    }
}

@Suite("Hello payload")
struct GatewayHelloTests {
    @Test func full() {
        let hello = GatewayHello(payload: Fixtures.json(#"""
        {"server":{"version":"2026.9.1"},"auth":{"scopes":["operator.read","operator.questions"]},
         "policy":{"maxPayload":1000,"tickIntervalMs":5000,"attachments":{"maxImageBytes":10,"maxBytes":20}},
         "features":{"methods":["chat.send","approval.history"]},"snapshot":{"a":1}}
        """#))
        #expect(hello.serverVersion == "2026.9.1")
        #expect(hello.scopes == ["operator.read", "operator.questions"] && hello.canAnswerQuestions)
        #expect(hello.maxPayload == 1000 && hello.tickIntervalMs == 5000)
        #expect(hello.maxImageBytes == 10 && hello.maxAttachmentBytes == 20)
        #expect(hello.methods == ["chat.send", "approval.history"])
        #expect(hello.snapshot == ["a": 1])
        #expect(hello.withheldScopes.isEmpty && hello.scopeUpgradeRequestId == nil)
    }

    @Test func missingFieldsUseDefaults() {
        let hello = GatewayHello(payload: [:])
        #expect(hello.serverVersion == nil && hello.scopes.isEmpty && hello.methods.isEmpty)
        #expect(hello.maxPayload == 25 * 1024 * 1024 && hello.tickIntervalMs == 15000)
        #expect(hello.maxImageBytes == nil && hello.maxAttachmentBytes == nil && absent(hello.snapshot))
        #expect(!hello.canAnswerQuestions)
        #expect(GatewayHello(payload: ["auth": ["scopes": ["operator.admin"]]]).canAnswerQuestions)
    }
}
