import Foundation
import Testing
@testable import PincerKit

@Suite("Command policy")
struct ExecPolicyTests {
    static let file = ExecApprovalsFile(Fixtures.json(#"""
    {"version":1,"socket":{"path":"/s","token":"secret"},"futureKey":{"keep":true},
     "defaults":{"security":"allowlist","ask":"on-miss"},
     "agents":{"*":{"ask":"always"},"main":{"security":"deny","futureAgentKey":1,"allowlist":[{"id":"e1","pattern":"/usr/bin/git"}]},
      "research":{"ask":"on-request"}}}
    """#))
    static let resolved = ExecApprovalsSnapshot(Fixtures.json(#"""
    {"path":"p","exists":true,"hash":"h","file":{"version":1},
     "resolvedDefaults":{"security":"full","ask":"off","askFallback":"deny","autoAllowSkills":false}}
    """#)).resolvedDefaults

    @Test func looseningRanks() {
        #expect(ExecPolicyField.security.isLoosening(from: "allowlist", to: "full"))
        #expect(!ExecPolicyField.security.isLoosening(from: "full", to: "deny"))
        #expect(ExecPolicyField.ask.isLoosening(from: "always", to: "off"))
        #expect(ExecPolicyField.security.isLoosening(from: "allowlist", to: "yolo"), "unknown new value")
        #expect(ExecPolicyField.security.isLoosening(from: nil, to: "full"), "missing old → loosest")
        #expect(ExecPolicyField.security.isLoosening(from: "weird", to: "full"), "unknown old → loosest")
        #expect(!ExecPolicyField.security.isLoosening(from: nil, to: "allowlist"))
        #expect(!ExecPolicyField.autoAllowSkills.isLoosening(from: nil, to: false))
        #expect(!ExecPolicyField.ask.isLoosening(from: "on-request", to: "on-request"))
    }

    @Test func wildcardInheritance() {
        let file = Self.file
        func effective(_ field: ExecPolicyField, _ agent: String?) -> JSONValue? {
            ExecPolicy.effectiveValue(field, agent: agent, in: file, saved: file, resolvedDefaults: Self.resolved)
        }
        #expect(effective(.ask, "main") == "always", "agent → *")
        #expect(effective(.ask, "coder") == "always", "agents not in the file inherit * too")
        #expect(effective(.ask, "research") == "on-request", "own override beats *")
        #expect(effective(.security, "coder") == "allowlist", "* doesn't set it → defaults")
        #expect(effective(.askFallback, "coder") == "deny", "then the Gateway default")
        #expect(effective(.ask, nil) == "on-miss")
        #expect(ExecPolicy.inheritedValue(.ask, agent: "*", in: file, saved: file, resolvedDefaults: Self.resolved) == "on-miss")
    }

    @Test func looseningChangesListedOnce() {
        let names = ["main": "Scout"]
        func changes(_ edit: (inout ExecApprovalsFile) -> Void, resolved: ExecPolicySettings? = Self.resolved) -> [String] {
            var draft = Self.file
            edit(&draft)
            return ExecPolicy.looseningChanges(from: Self.file, to: draft, resolvedDefaults: resolved, agentNames: names)
        }
        #expect(changes { $0.set(.security, "full", agent: "main") } == ["Scout: Commands → Allow any command"])
        #expect(changes { $0.set(.ask, nil, agent: "*") } == ["All agents: Ask for approval → When not on the allowlist"])
        #expect(changes { $0.set(.security, "full", agent: nil) } == ["Defaults: Commands → Allow any command"])
        #expect(changes { $0.set(.ask, "always", agent: "main") }.isEmpty, "same as the inherited * value")
        #expect(changes { $0.removeAllowlistEntry(agent: "main", at: 0) }.isEmpty)
        #expect(changes({ $0.set(.autoAllowSkills, true, agent: nil) }, resolved: nil) == ["Defaults: Trust skill commands → On"],
                "no resolvedDefaults")
    }

    @Test func outgoingFile() {
        var draft = Self.file
        draft.set(.ask, "always", agent: "main")
        draft.set(.security, "deny", agent: "coder")
        draft.set(.security, nil, agent: "coder")
        let snapshot = ExecApprovalsSnapshot(["path": "p", "exists": true, "hash": "h1", "file": Self.file.raw])
        let params = ExecPolicy.setParams(draft: draft, snapshot: snapshot)
        let sent = params["file"]
        #expect(params["baseHash"] == "h1")
        #expect(sent?["socket"] == ["path": "/s"], "socket.token never sent")
        #expect(sent?["futureKey"] == ["keep": true] && sent?["agents"]?["main"]?["futureAgentKey"] == 1, "unknown keys kept")
        #expect(sent?["agents"]?["main"]?["ask"] == "always" && sent?["agents"]?["main"]?["allowlist"]?[0]?["id"] == "e1")
        #expect(absent(sent?["agents"]?["coder"]), "agent emptied by edits is dropped")
        #expect(sent?["agents"]?["research"]?["ask"] == "on-request", "unknown value round-trips")
    }

    @Test func errorClassification() {
        #expect(ExecPolicyError.classify(GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                                          details: ["code": "MISSING_SCOPE", "scope": "operator.admin"])) == .needsAdmin)
        #expect(ExecPolicyError.classify(GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: exec.approvals.get",
                                                          details: nil)) == .unsupported)
        #expect(ExecPolicyError.classify(GatewayError.rpc(
            code: "INVALID_REQUEST", message: "exec approvals changed since last load; re-run exec.approvals.get and retry", details: nil))
            == .conflict)
        #expect(ExecPolicyError.classify(GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid exec.approvals.set params: x",
                                                          details: nil)) == .validation("invalid exec.approvals.set params: x"))
    }
}
