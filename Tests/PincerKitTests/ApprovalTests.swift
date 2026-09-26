import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Approval records")
struct ApprovalRecordTests {
    @Test func execRecord() throws {
        let record = try #require(ApprovalRecord(Fixtures.json(#"""
        {"id":"a1","kind":"exec","status":"allowed","decision":"allow-always","createdAtMs":1700000000000,
         "resolvedAtMs":1700000005000,"source":{"agentId":"main","sessionKey":"agent:main:main"},
         "resolver":{"kind":"device","id":"abcdef123456"},
         "presentation":{"commandText":"rm -rf build","host":"mac","warningText":""}}
        """#)))
        #expect(record.id == "a1" && record.kind == .exec && record.status == .allowed && record.decision == .allowAlways)
        #expect(record.commandText == "rm -rf build" && record.host == "mac" && record.warningText == nil)
        #expect(record.displayTitle == "rm -rf build" && record.statusLabel == "Always allowed" && record.tone == .allowed)
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(record.resolvedAt == Date(timeIntervalSince1970: 1_700_000_005))
        #expect(record.agentId == "main" && record.sessionKey == "agent:main:main")
        #expect(record.resolver == ApprovalRecord.Resolver(kind: "device", id: "abcdef123456"))
    }

    @Test func inferredFields() throws {
        let fromDecision = try #require(ApprovalRecord(["id": "a2", "command": "ls", "decision": "deny", "reason": "no-route"]))
        #expect(fromDecision.kind == .exec && fromDecision.status == .denied && fromDecision.reason == .noRoute)
        #expect(fromDecision.statusLabel == "Denied · No reviewer" && fromDecision.tone == .denied)
        let byUser = try #require(ApprovalRecord(["id": "a3", "status": "denied", "reason": "user"]))
        #expect(byUser.statusLabel == "Denied" && byUser.kind == .other("unknown"))
        let plugin = try #require(ApprovalRecord(["id": "a4", "kind": "plugin", "status": "canceled", "title": "Install"]))
        #expect(plugin.kind == .plugin && plugin.status == .cancelled && plugin.displayTitle == "Install" && plugin.tone == .neutral)
        let system = try #require(ApprovalRecord(["id": "a5", "kind": "system", "status": "timed-out"]))
        #expect(system.kind == .systemAgent && system.status == .other("timed-out") && system.statusLabel == "Timed out")
        #expect(ApprovalRecord(["id": "a6"])?.status == .other("unknown"))
    }

    @Test func invalid() {
        #expect(ApprovalRecord(["kind": "exec"]) == nil)
        #expect(ApprovalRecord(["id": "  "]) == nil)
        #expect(ApprovalRecord("a1") == nil)
    }

    @Test func decidedBy() {
        typealias R = ApprovalRecord.Resolver
        #expect(ApprovalRecord.decidedBy(R(kind: "device", id: "abcdef123456"), localDeviceId: "abcdef123456") == "This device")
        #expect(ApprovalRecord.decidedBy(R(kind: "device", id: "abcdef123456"), localDeviceId: "other") == "Another device (abcdef…)")
        #expect(ApprovalRecord.decidedBy(R(kind: "device", id: "abcdef123456"), localDeviceId: nil) == "Another device (abcdef…)")
        #expect(ApprovalRecord.decidedBy(R(kind: "device"), localDeviceId: "x") == "Another device")
        #expect(ApprovalRecord.decidedBy(R(kind: "channel", id: "discord"), localDeviceId: nil) == "Channel · discord")
        #expect(ApprovalRecord.decidedBy(R(kind: "channel"), localDeviceId: nil) == "Channel")
        #expect(ApprovalRecord.decidedBy(R(kind: "runtime"), localDeviceId: nil) == "Runtime")
        #expect(ApprovalRecord.decidedBy(R(kind: "system"), localDeviceId: nil) == "OpenClaw (automatic)")
        #expect(ApprovalRecord.decidedBy(R(kind: "policy-engine", id: "p1"), localDeviceId: nil) == "Policy engine · p1")
        #expect(ApprovalRecord.decidedBy(nil, localDeviceId: nil) == "Unknown")
    }

    @Test func kindFilterWireValue() {
        typealias F = ApprovalHistoryModel.KindFilter
        #expect(F.allCases.map(\.wireValue) == [nil, "exec", "plugin", "system-agent"])
        #expect(F.all.emptyMessage == nil && F.exec.emptyMessage != nil)
    }

    @Test func invalidCursor() {
        #expect(ApprovalHistoryModel.isInvalidCursor(GatewayError.rpc(code: "INVALID_REQUEST", message: "bad cursor", details: nil)))
        #expect(ApprovalHistoryModel.isInvalidCursor(GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid",
                                                                      details: ["reason": "CURSOR_EXPIRED"])))
        #expect(!ApprovalHistoryModel.isInvalidCursor(GatewayError.rpc(code: "INVALID_REQUEST", message: "bad kind", details: nil)))
        #expect(!ApprovalHistoryModel.isInvalidCursor(GatewayError.rpc(code: "UNAVAILABLE", message: "cursor", details: nil)))
        #expect(!ApprovalHistoryModel.isInvalidCursor(GatewayError.notConnected))
    }
}

/// Scripted `approval.history` pages, keyed by cursor ("" for the first page).
@MainActor
final class ScriptedHistory {
    var pages: [String: JSONValue] = [:]
    var failures: [String: GatewayError] = [:]
    var calls: [JSONValue] = []

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        #expect(method == "approval.history")
        self.calls.append(params)
        let cursor = params["cursor"]?.string ?? ""
        if let failure = self.failures.removeValue(forKey: cursor) { throw failure }
        return self.pages[cursor] ?? ["items": []]
    }

    static func page(_ ids: [String], next: String?) -> JSONValue {
        ["items": .array(ids.map { ["id": .string($0), "status": "allowed"] }), "nextCursor": JSONValue(next)]
    }
}

@MainActor
@Suite("Approval history paging")
struct ApprovalHistoryModelTests {
    func model(_ script: ScriptedHistory, methods: Set<String>? = nil) -> ApprovalHistoryModel {
        let model = ApprovalHistoryModel(methods: { methods }, localDeviceId: "me") { try await script.request($0, $1) }
        model.pageSize = 2
        return model
    }

    @Test func pagesUntilExhausted() async {
        let script = ScriptedHistory()
        script.pages = ["": ScriptedHistory.page(["1", "2"], next: "c1"),
                        "c1": ScriptedHistory.page(["2", "3"], next: "c2"),
                        "c2": ScriptedHistory.page([], next: "c3")]
        let model = self.model(script)
        await model.load()
        #expect(model.items.map(\.id) == ["1", "2"] && model.hasMore && model.hasLoaded && model.supported)
        #expect(script.calls.first == ["limit": 2])
        await model.loadMore()
        #expect(model.items.map(\.id) == ["1", "2", "3"] && model.nextCursor == "c2")
        #expect(script.calls.last == ["limit": 2, "cursor": "c1"])
        await model.loadMore()
        #expect(model.items.map(\.id) == ["1", "2", "3"] && !model.hasMore, "an empty page ends paging")
        await model.loadMore()
        #expect(script.calls.count == 3)
    }

    @Test func repeatedCursorEndsPaging() async {
        let script = ScriptedHistory()
        script.pages = ["": ScriptedHistory.page(["1"], next: "c1"), "c1": ScriptedHistory.page(["2"], next: "c1")]
        let model = self.model(script)
        await model.load()
        await model.loadMore()
        #expect(model.items.map(\.id) == ["1", "2"] && !model.hasMore)
    }

    @Test func kindFilterIsSent() async {
        let script = ScriptedHistory()
        script.pages = ["": ScriptedHistory.page(["1"], next: nil)]
        let model = self.model(script)
        await model.setKindFilter(.systemAgent)
        #expect(script.calls.last == ["limit": 2, "kind": "system-agent"] && model.kindFilter == .systemAgent)
        await model.setKindFilter(.systemAgent)
        #expect(script.calls.count == 1, "same filter doesn't reload")
    }

    @Test func invalidCursorRestarts() async {
        let script = ScriptedHistory()
        script.pages = ["": ScriptedHistory.page(["1"], next: "stale")]
        script.failures = ["stale": .rpc(code: "INVALID_REQUEST", message: "invalid cursor", details: nil)]
        let model = self.model(script)
        await model.load()
        await model.loadMore()
        #expect(script.calls.map { $0["cursor"]?.string } == [nil, "stale", nil])
        #expect(model.items.map(\.id) == ["1"] && model.loadMoreState == .idle && model.hasMore)
    }

    @Test func errorsAndUnsupported() async {
        let script = ScriptedHistory()
        script.failures = ["": .rpc(code: "FORBIDDEN", message: "missing operator.approvals", details: nil)]
        let model = self.model(script)
        await model.load()
        #expect(model.loadState == .failed(ApprovalHistoryModel.missingScopeMessage))

        script.failures = ["": .rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)]
        await model.load()
        #expect(!model.supported && model.items.isEmpty && model.loadState == .idle)

        let advertised = ScriptedHistory()
        let old = self.model(advertised, methods: ["chat.send"])
        await old.load()
        #expect(!old.supported && advertised.calls.isEmpty)
        #expect(old.decidedBy(ApprovalRecord(["id": "x", "resolver": ["kind": "device", "id": "me"]])!) == "This device")
    }
}
