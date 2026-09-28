import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runExecApprovalChecks() {
    let approval = ExecApproval(json(#"{"id":"ap1","request":{"command":"rm -rf build","cwd":"/p","sessionKey":"agent:main:main"},"expiresAtMs":1}"#))
    check(approval?.id == "ap1" && approval?.command == "rm -rf build" && approval?.cwd == "/p", "approval payload")
    check(approval?.allowedDecisions == nil && approval?.allowsAlways == true && approval.map(Notifier.category(for:)) == "approval",
          "no allowedDecisions (older gateway) → all three actions")
    check(approval?.isExpired() == true && approval?.isExpired(at: Date(timeIntervalSince1970: 0)) == false, "expiresAtMs past → expired")
    let onceOnlyApproval = ExecApproval(json(#"{"id":"ap2","request":{"command":"x","allowedDecisions":["allow-once","deny"]},"expiresAtMs":4102444800000}"#))
    check(onceOnlyApproval?.allowedDecisions == ["allow-once", "deny"] && onceOnlyApproval?.allowsAlways == false
          && onceOnlyApproval.map(Notifier.category(for:)) == "approval-once" && onceOnlyApproval?.isExpired() == false,
          "allowedDecisions without allow-always → approval-once")
    let alwaysApproval = ExecApproval(json(#"{"id":"ap3","request":{"command":"x","allowedDecisions":["allow-once","allow-always","deny"]}}"#))
    check(alwaysApproval?.allowsAlways == true && alwaysApproval.map(Notifier.category(for:)) == "approval"
          && alwaysApproval?.isExpired() == false, "allowedDecisions with allow-always → approval, no expiry")
}

@MainActor
func runApprovalNotificationActionChecks() {
    do {
        let categories = Dictionary(uniqueKeysWithValues: Notifier.categories().map { ($0.identifier, $0) })
        check(Set(categories.keys) == ["reply", "approval", "approval-once", "approval-push"], "registered categories")
        check(categories["approval"]?.actions.map(\.identifier) == ["approve-once", "approve-always", "deny"]
              && categories["approval"]?.actions.map(\.title) == ["Allow once", "Always allow", "Deny"],
              "approval: Allow once, Always allow, Deny in order")
        check(categories["approval-push"]?.actions.map(\.identifier) == ["approve-once", "approve-always", "deny"],
              "legacy approval-push keeps the same actions")
        check(categories["approval-once"]?.actions.map(\.identifier) == ["approve-once", "deny"], "approval-once has no Always allow")
        check(categories["reply"]?.actions.isEmpty == true, "reply has no actions")
        let approvalActions = Notifier.approvalCategories.flatMap { categories[$0]?.actions ?? [] }
        check(approvalActions.count == 8 && approvalActions.allSatisfy { !$0.options.contains(.foreground) }, "no approval action opens the app")
        check(approvalActions.filter { $0.identifier != "deny" }.allSatisfy { $0.options.contains(.authenticationRequired) }, "Allow actions need unlocking")
        check(approvalActions.filter { $0.identifier == "deny" }.allSatisfy { !$0.options.contains(.authenticationRequired) && $0.options.contains(.destructive) },
              "Deny is destructive and works locked")
        check(Notifier.approvalCategories == ["approval", "approval-once", "approval-push"], "approval categories")

        check(Notifier.approvalDecision(for: "approve-once") == "allow-once" && Notifier.approvalDecision(for: "approve-always") == "allow-always"
              && Notifier.approvalDecision(for: "deny") == "deny", "action → decision")
        check([UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier, "allow-once", "open", ""]
              .allSatisfy { Notifier.approvalDecision(for: $0) == nil }, "tap, dismiss and unknown actions decide nothing")

        let gw = UUID()
        let info: [AnyHashable: Any] = ["gateway": gw.uuidString, "approval": "a1", "session": "agent:main:main"]
        for (action, decision) in [("approve-once", "allow-once"), ("approve-always", "allow-always"), ("deny", "deny")] {
            check(Notifier.interpret(actionIdentifier: action, categoryIdentifier: "approval", userInfo: info)
                  == .resolve(gatewayId: gw, approvalId: "a1", decision: decision), "\(action) resolves on its own gateway")
        }
        check(Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: "approval-push", userInfo: info)
              == .resolve(gatewayId: gw, approvalId: "a1", decision: "deny")
              && Notifier.interpret(actionIdentifier: "approve-once", categoryIdentifier: "approval-once", userInfo: info)
              == .resolve(gatewayId: gw, approvalId: "a1", decision: "allow-once"), "legacy and once-only categories resolve")
        check(Notifier.interpret(actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "approval", userInfo: info)
              == .open(Notifier.Target(gatewayId: gw, sessionKey: "agent:main:main")), "plain tap opens the chat")
        check(Notifier.interpret(actionIdentifier: UNNotificationDismissActionIdentifier, categoryIdentifier: "approval", userInfo: info) == .none,
              "dismiss sends nothing")
        check(Notifier.interpret(actionIdentifier: "bogus", categoryIdentifier: "approval", userInfo: info) == .none, "unknown action does nothing")
        check(Notifier.interpret(actionIdentifier: "approve-once", categoryIdentifier: "reply", userInfo: info) == .none,
              "approval action on a reply notification is dropped")
        check(Notifier.interpret(actionIdentifier: "approve-once", categoryIdentifier: "approval", userInfo: ["approval": "a1"]) == .none,
              "missing gateway → nothing sent")
        check(Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: "approval", userInfo: ["gateway": "not-a-uuid", "approval": "a1"]) == .none,
              "invalid gateway → nothing sent")
        check(Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: "approval", userInfo: ["gateway": gw.uuidString]) == .none
              && Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: "approval", userInfo: ["gateway": gw.uuidString, "approval": ""]) == .none,
              "missing approval id → nothing sent")
        check(Notifier.interpret(actionIdentifier: "approve-once", categoryIdentifier: "approval",
                                 userInfo: ["pincer": ["g": gw.uuidString, "p": "sealed"]]) == .open(Notifier.Target(gatewayId: gw, sessionKey: "")),
              "undecrypted push (only pincer.g) never resolves, opens its gateway")
        check(Notifier.interpret(actionIdentifier: "deny", categoryIdentifier: "approval",
                                 userInfo: ["gateway": gw.uuidString.lowercased(), "approval": "a1"])
              == .resolve(gatewayId: gw, approvalId: "a1", decision: "deny"), "lowercase gateway UUID → same gateway")
    }
}

@MainActor
func runApprovalOutcomeChecks() async {
    do {
        func rpc(_ code: String, _ message: String, _ details: JSONValue? = nil) -> Error {
            GatewayError.rpc(code: code, message: message, details: details)
        }
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "approval expired or not found", ["reason": "APPROVAL_NOT_FOUND"])) == .expired,
              "APPROVAL_NOT_FOUND → expired")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "something", ["reason": "APPROVAL_NOT_FOUND"])) == .expired, "reason alone → expired")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "unknown or expired approval id")) == .expired, "legacy message → expired")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "approval expired or not found")) == .expired, "message without details → expired")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "approval already resolved", ["reason": "APPROVAL_ALREADY_RESOLVED"]))
              == .answeredElsewhere(decision: nil), "APPROVAL_ALREADY_RESOLVED → answered elsewhere")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "approval already resolved")) == .answeredElsewhere(decision: nil),
              "already-resolved message → answered elsewhere")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "approval already resolved", ["reason": "APPROVAL_ALREADY_RESOLVED", "decision": "deny"]))
              == .answeredElsewhere(decision: "deny"), "decision carried when the Gateway sends it")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "allow-always is unavailable for this command", ["reason": "APPROVAL_ALLOW_ALWAYS_UNAVAILABLE"]))
              == .allowAlwaysUnavailable, "APPROVAL_ALLOW_ALWAYS_UNAVAILABLE → still pending")
        check([GatewayError.timeout("exec.approval.resolve"), .notConnected, .closed("gone")].allSatisfy { ApprovalOutcome.classify($0) == .unreachable }
              && ApprovalOutcome.classify(rpc("UNAVAILABLE", "gateway restarting")) == .unreachable,
              "timeout, not connected, closed, UNAVAILABLE → unreachable")
        check(ApprovalOutcome.classify(rpc("FORBIDDEN", "nope")) == .notPermitted
              && ApprovalOutcome.classify(rpc("INVALID_REQUEST", "missing scope: operator.approvals")) == .notPermitted,
              "FORBIDDEN or missing scope → not permitted")
        check(ApprovalOutcome.classify(rpc("INVALID_REQUEST", "invalid decision")) == .failed("invalid decision"), "other error keeps its message")

        let removing: [ApprovalOutcome] = [.resolved, .expired, .answeredElsewhere(decision: nil)]
        let keeping: [ApprovalOutcome] = [.alreadyHandled, .allowAlwaysUnavailable, .unreachable, .notPermitted, .unknownGateway, .failed("x")]
        check(removing.allSatisfy(\.removesApproval) && !keeping.contains(where: \.removesApproval), "which outcomes remove the approval")

        let name = "Home Lab"
        check(ApprovalOutcome.resolved.followUpBody(gatewayName: name) == nil && ApprovalOutcome.alreadyHandled.followUpBody(gatewayName: name) == nil,
              "no follow-up on success or a duplicate")
        check(ApprovalOutcome.expired.followUpBody(gatewayName: name) == "That approval expired. Nothing was run.", "expired copy")
        check(ApprovalOutcome.answeredElsewhere(decision: nil).followUpBody(gatewayName: name) == "Already answered elsewhere."
              && ApprovalOutcome.answeredElsewhere(decision: "deny").followUpBody(gatewayName: name) == "Already denied elsewhere.",
              "answered elsewhere copy")
        check(ApprovalOutcome.allowAlwaysUnavailable.followUpBody(gatewayName: name) == "Always allow isn't available for this command.",
              "allow-always unavailable copy")
        check(ApprovalOutcome.unreachable.followUpBody(gatewayName: name) == "Couldn't reach Home Lab — the command is still waiting.",
              "unreachable copy names the gateway")
        check(ApprovalOutcome.notPermitted.followUpBody(gatewayName: name) == "This device can't approve commands on Home Lab. Open Pincer for details.",
              "not permitted copy names the gateway")
        check(ApprovalOutcome.unknownGateway.followUpBody(gatewayName: nil) == "This gateway is no longer in Pincer.", "unknown gateway copy")
        check(ApprovalOutcome.failed("boom").followUpBody(gatewayName: name) == "boom"
              && (ApprovalOutcome.failed(String(repeating: "x", count: 500)).followUpBody(gatewayName: name)?.count ?? 0) <= 220,
              "other errors show the clipped message")

        check(ApprovalOutcome.allowAlwaysUnavailable.followUpCategory(original: "approval") == "approval-once", "still pending: Allow once and Deny")
        check(ApprovalOutcome.unreachable.followUpCategory(original: "approval") == "approval"
              && ApprovalOutcome.unreachable.followUpCategory(original: "approval-push") == "approval"
              && ApprovalOutcome.unreachable.followUpCategory(original: "approval-once") == "approval-once", "unreachable keeps the actions")
        check([ApprovalOutcome.expired, .answeredElsewhere(decision: nil), .notPermitted, .unknownGateway, .failed("x")]
              .allSatisfy { $0.followUpCategory(original: "approval") == "reply" }, "final outcomes have no actions")
        check(ApprovalOutcome.resolved.inAppMessage(gatewayName: name) == nil && ApprovalOutcome.expired.inAppMessage(gatewayName: name) == nil
              && ApprovalOutcome.unreachable.inAppMessage(gatewayName: name)?.contains("Home Lab") == true, "in-app messages")

        let gw = UUID()
        let command = "rm -rf ./build"
        let all: [ApprovalOutcome] = [.expired, .answeredElsewhere(decision: "allow-once"), .allowAlwaysUnavailable, .unreachable, .notPermitted, .unknownGateway, .failed("bad")]
        let contents = all.map {
            Notifier.followUpContent(for: $0, gatewayId: gw, gatewayName: name, context: "Build chat", approvalId: "a1",
                                     sessionKey: "agent:main:main", threadIdentifier: "\(gw.uuidString)|agent:main:main", originalCategory: "approval")
        }
        check(contents.allSatisfy { $0 != nil }, "a follow-up for every stale or failed outcome")
        check(contents.compactMap(\.self).allSatisfy { !$0.body.contains(command) && !$0.title.contains(command) && $0.title.contains(name) },
              "follow-ups name the gateway and never the command")
        check(contents.compactMap(\.self).allSatisfy {
            $0.interruptionLevel != .timeSensitive && $0.threadIdentifier == "\(gw.uuidString)|agent:main:main"
                && $0.userInfo["gateway"] as? String == gw.uuidString && $0.userInfo["approval"] as? String == "a1"
        }, "follow-ups keep the thread and ids, not time-sensitive")
        check(contents.first??.title.contains("Build chat") == true, "follow-up names the chat")
        check(Notifier.followUpContent(for: .resolved, gatewayId: gw, gatewayName: name, context: nil, approvalId: "a1",
                                       sessionKey: nil, threadIdentifier: nil, originalCategory: "approval") == nil, "no follow-up on success")

        // In-flight guard: a second resolve of the same id while the first waits sends nothing.
        let offline = GatewayProfile(name: "Offline", url: "ws://127.0.0.1:9", authMode: .none)
        let store = GatewayStore(profile: offline)
        async let first = store.resolveApproval(id: "a1", decision: "allow-once", connectWithin: 1, timeout: 1)
        async let second = store.resolveApproval(id: "a1", decision: "allow-once", connectWithin: 1, timeout: 1)
        let pair = await [first, second]
        check(pair.contains(.unreachable) && pair.contains(.alreadyHandled), "concurrent resolves: one attempt, one no-op (\(pair))")
        check(store.lastError?.contains("Offline") == true, "unreachable shows in lastError")
        let retry = await store.resolveApproval(id: "a1", decision: "allow-once", connectWithin: 0.5, timeout: 0.5)
        check(retry == .unreachable, "a dropped decision can be retried, never buffered")

        let (modelDefaults, modelSuite) = scratchDefaults()
        let model = AppModel(defaults: modelDefaults)
        let unknown = await model.respondToApproval(gatewayId: UUID(), approvalId: "a1", decision: "allow-once")
        check(unknown == .unknownGateway, "notification for a removed gateway → no longer in Pincer, nothing sent")
        UserDefaults.standard.removePersistentDomain(forName: modelSuite)
    }
}

@MainActor
func runApprovalHistoryChecks() {
    do {
        let localDevice = String(repeating: "d", count: 64)
        let exec = ApprovalRecord(json(#"""
        {"id":"exec_1","urlPath":"/approve/exec_1","createdAtMs":1000,"expiresAtMs":121000,"resolvedAtMs":5000,
         "status":"allowed","decision":"allow-once","reason":"user",
         "source":{"agentId":"coder","sessionKey":"agent:coder:main"},"resolver":{"kind":"device","id":"\#(localDevice)"},
         "presentation":{"kind":"exec","commandText":"rm -rf ./build","commandPreview":"rm -rf …","warningText":"Deletes files.",
          "host":"node","nodeId":"node-1","agentId":"main","allowedDecisions":["allow-once","allow-always","deny"]}}
        """#))
        check(exec?.id == "exec_1" && exec?.kind == .exec && exec?.status == .allowed && exec?.decision == .allowOnce
              && exec?.reason == .user && exec?.urlPath == "/approve/exec_1", "exec snapshot decodes")
        check(exec?.commandText == "rm -rf ./build" && exec?.commandPreview == "rm -rf …" && exec?.warningText == "Deletes files."
              && exec?.host == "node" && exec?.nodeId == "node-1" && exec?.displayTitle == "rm -rf ./build", "exec presentation fields")
        check(exec?.createdAt == Date(timeIntervalSince1970: 1) && exec?.expiresAt == Date(timeIntervalSince1970: 121)
              && exec?.resolvedAt == Date(timeIntervalSince1970: 5), "timestamps from *AtMs")
        check(exec?.agentId == "coder" && exec?.sessionKey == "agent:coder:main", "source wins over presentation agent")
        check(exec?.statusLabel == "Allowed once" && exec?.tone == .allowed, "allowed once capsule")
        check(exec?.decidedBy(localDeviceId: localDevice) == "This device", "resolver matching this device → This device")
        check(exec?.decidedBy(localDeviceId: "other") == "Another device (dddddd…)", "resolver on another device")
        check(exec?.decidedBy(localDeviceId: nil) == "Another device (dddddd…)", "no local id → another device")

        let plugin = ApprovalRecord(json(#"""
        {"id":"plugin_1","createdAtMs":1,"expiresAtMs":2,"resolvedAtMs":3,"status":"allowed","decision":"allow-always","reason":"user",
         "resolver":{"kind":"channel","id":"discord:ops"},
         "presentation":{"kind":"plugin","title":"Send email","description":"Email 3 people.","detail":"To: a@example.com",
          "severity":"warning","pluginId":"mail","toolName":"send_email","agentId":"main","allowedDecisions":["allow-once","deny"]}}
        """#))
        check(plugin?.kind == .plugin && plugin?.title == "Send email" && plugin?.description == "Email 3 people."
              && plugin?.detail == "To: a@example.com" && plugin?.severity == "warning" && plugin?.pluginId == "mail"
              && plugin?.toolName == "send_email", "plugin presentation fields")
        check(plugin?.agentId == "main" && plugin?.sessionKey == nil, "agent from presentation without source")
        check(plugin?.displayTitle == "Send email" && plugin?.statusLabel == "Always allowed" && plugin?.tone == .allowed, "always allowed capsule")
        check(plugin?.decidedBy(localDeviceId: localDevice) == "Channel · discord:ops", "channel resolver")

        let system = ApprovalRecord(json(#"""
        {"id":"sys_1","status":"denied","decision":"deny","reason":"no-route","resolver":{"kind":"system"},
         "presentation":{"kind":"system-agent","title":"Enable plugin","description":"Enable browser.","proposalHash":"ab","agentId":"main"}}
        """#))
        check(system?.kind == .systemAgent && system?.kind.rawValue == "system-agent" && system?.title == "Enable plugin", "system-agent decodes")
        check(system?.statusLabel == "Denied · No reviewer" && system?.tone == .denied, "denied no-route capsule")
        check(system?.decidedBy(localDeviceId: localDevice) == "OpenClaw (automatic)", "system resolver")
        check(system?.reason?.explanation.isEmpty == false, "reason explained")

        let malformed = ApprovalRecord(json(#"{"id":"d2","status":"denied","decision":"deny","reason":"malformed-verdict","resolver":{"kind":"runtime"},"presentation":{"kind":"exec","commandText":"x"}}"#))
        check(malformed?.statusLabel == "Denied · Invalid response" && malformed?.decidedBy(localDeviceId: nil) == "Runtime",
              "denied malformed-verdict capsule, runtime resolver")
        let byUser = ApprovalRecord(json(#"{"id":"d3","status":"denied","decision":"deny","reason":"user","presentation":{"kind":"exec","commandText":"x"}}"#))
        check(byUser?.statusLabel == "Denied" && byUser?.decidedBy(localDeviceId: nil) == "Unknown", "denied by user, missing resolver → Unknown")
        let expired = ApprovalRecord(json(#"{"id":"e1","status":"expired","reason":"timeout","presentation":{"kind":"exec","commandText":"x"}}"#))
        check(expired?.status == .expired && expired?.decision == nil && expired?.statusLabel == "Expired" && expired?.tone == .neutral,
              "expired capsule")
        let cancelled = ApprovalRecord(json(#"{"id":"c1","status":"cancelled","reason":"gateway-restart","presentation":{"kind":"exec","commandText":"x"}}"#))
        check(cancelled?.status == .cancelled && cancelled?.reason == .gatewayRestart && cancelled?.statusLabel == "Cancelled"
              && cancelled?.tone == .neutral, "cancelled capsule")
        let pending = ApprovalRecord(json(#"{"id":"p1","status":"pending","sourceSessionKey":"agent:main:main","presentation":{"kind":"exec","commandText":"ls"}}"#))
        check(pending?.status == .pending && pending?.sessionKey == "agent:main:main" && pending?.resolvedAt == nil, "pending approval.get snapshot")

        let unknown = ApprovalRecord(json(#"""
        {"id":"u1","status":"escalated","reason":"quorum-lost","futureField":{"x":1},"resolver":{"kind":"committee","id":"c9"},
         "presentation":{"kind":"mcp-tool","title":"Call tool","extra":true}}
        """#))
        check(unknown?.kind == .other("mcp-tool") && unknown?.kind.rawValue == "mcp-tool" && unknown?.kind.label == "Mcp tool",
              "unknown kind kept raw, capitalized")
        check(unknown?.status == .other("escalated") && unknown?.statusLabel == "Escalated" && unknown?.reason == .other("quorum-lost")
              && unknown?.reason?.shortLabel == "Quorum lost", "unknown status/reason kept raw, extra fields ignored")
        check(unknown?.decidedBy(localDeviceId: nil) == "Committee · c9", "unknown resolver kind humanized")
        check(ApprovalRecord(json(#"{"status":"allowed","presentation":{"kind":"exec","commandText":"ls"}}"#)) == nil, "record without id rejected")
        check(ApprovalRecord(json(#"{"id":""}"#)) == nil && ApprovalRecord(json(#""ap1""#)) == nil, "empty id and non-objects rejected")
        let legacy = ApprovalRecord(json(#"{"id":"l1","kind":"exec","command":"make","decision":"deny","requestedAtMs":2000,"decidedAtMs":4000,"agentId":"main","sessionKey":"agent:main:main"}"#))
        check(legacy?.kind == .exec && legacy?.commandText == "make" && legacy?.status == .denied
              && legacy?.createdAt == Date(timeIntervalSince1970: 2) && legacy?.resolvedAt == Date(timeIntervalSince1970: 4)
              && legacy?.agentId == "main" && legacy?.sessionKey == "agent:main:main", "flat legacy record, status from decision, requested/decidedAtMs")
        check(ApprovalRecord(json(#"{"id":"l2","decision":"allow-always"}"#))?.status == .allowed, "missing status derived from allow decision")
        check(ApprovalRecord(json(#"{"id":"l3","presentation":{"commandText":"ls"}}"#))?.kind == .exec, "kind inferred from commandText")
        check(ApprovalHistoryModel.KindFilter.allCases.map(\.label) == ["All", "Commands", "Plugins", "System"]
              && ApprovalHistoryModel.KindFilter.all.wireValue == nil && ApprovalHistoryModel.KindFilter.systemAgent.wireValue == "system-agent",
              "kind filter labels and wire values")
        check(ApprovalHistoryModel.KindFilter.exec.emptyMessage == "No command approvals in the last 30 days."
              && ApprovalHistoryModel.KindFilter.all.emptyMessage == nil, "filtered empty messages")
    }
}

@MainActor
func runAgentQuestionChecks() {
    do {
        let record = json(#"""
        {"id":"ask_1","agentId":"main","sessionKey":"agent:main:discord:channel:1","runId":"r1","createdAtMs":1000,
         "expiresAtMs":4102444800000,"status":"pending","questions":[
          {"questionId":"discord_remove","header":"Discord","question":"What do you want removed?","isOther":true,"options":[
            {"label":"Disconnect Discord from OpenClaw","description":"Remove the config"},
            {"label":"Delete one channel","description":""},
            {"label":"Stop watching"}]},
          {"questionId":"tags","header":"Tags","question":"Which tags?","multiSelect":true,"options":[{"label":"a"},{"label":"b"},{"label":"c"}]},
          {"questionId":"why","header":"Why","question":"Why?","options":[]}]}
        """#)
        let prompt = QuestionPrompt(record)
        check(prompt?.id == "ask_1" && prompt?.questions.count == 3 && prompt?.sessionKey == "agent:main:discord:channel:1",
              "question.requested record parses")
        check(QuestionPrompt(json(#"{"question":{"id":"ask_2","expiresAtMs":1,"questions":[{"questionId":"q","header":"","question":"Q?","options":[]}]}}"#))?.id == "ask_2",
              "question.get wrapper parses")
        check(QuestionPrompt(json(#"{"id":"ask_3","questions":[]}"#)) == nil, "prompt without questions rejected")
        check(QuestionPrompt(json(#"{"questions":[{"questionId":"q","question":"Q?"}]}"#)) == nil, "prompt without id rejected")
        // ask_user tool arguments use `id` rather than `questionId`.
        check(AgentQuestion(json(#"{"id":"q1","header":"H","question":"Q?","options":[]}"#))?.questionId == "q1", "tool-argument question id")
        check(AgentQuestion(json(#"{"questionId":"q","question":"Q?","url":"javascript:alert(1)"}"#))?.url == nil
              && AgentQuestion(json(#"{"questionId":"q","question":"Q?","url":"https://example.com/x"}"#))?.url?.host() == "example.com",
              "only http(s) question links")
        if let prompt {
            let single = prompt.questions[0], multi = prompt.questions[1], open = prompt.questions[2]
            check(single.options.count == 3 && single.options[0].description == "Remove the config" && single.options[1].description == nil,
                  "options keep descriptions, blank ones dropped")
            check(single.allowsFreeText && !multi.allowsFreeText && open.allowsFreeText, "free text needs isOther or no options")
            check(prompt.isAnswerable(at: Date(timeIntervalSince1970: 2000)), "pending prompt answerable")
            check(prompt.isExpired(at: Date(timeIntervalSince1970: 4_102_444_800)), "prompt expires at expiresAtMs")
            check(prompt.belongs(to: "agent:main:discord:channel:1") && prompt.belongs(to: "AGENT:main:discord:channel:1")
                  && !prompt.belongs(to: "agent:main:main") && prompt.belongs(to: nil), "prompt matched to its chat")
            check(QuestionPrompt(json(#"{"id":"x","status":"answered","questions":[{"questionId":"q","question":"Q?"}]}"#))?.isAnswerable() == false,
                  "answered prompt not answerable")

            var draft = QuestionDraft()
            check(draft.answers(for: prompt) == nil, "no answers until every question has one")
            draft.toggle("Delete one channel", in: single)
            draft.toggle("Disconnect Discord from OpenClaw", in: single)
            check(draft.values(for: single) == ["Disconnect Discord from OpenClaw"], "single choice replaces the pick")
            draft.toggle("Disconnect Discord from OpenClaw", in: single)
            check(draft.values(for: single) == nil, "tapping the pick again clears it")
            draft.toggle("Not an option", in: single)
            check(draft.values(for: single) == nil, "unknown labels ignored")
            check(draft.toggle(number: 3, in: single) && draft.values(for: single) == ["Stop watching"], "number key picks an option")
            check(!draft.toggle(number: 4, in: single) && !draft.toggle(number: 0, in: single), "out-of-range number keys ignored")
            draft.setText("  Remove just #gyms  ", for: single)
            check(draft.values(for: single) == ["Remove just #gyms"], "typed answer replaces a single pick, trimmed")
            draft.toggle("Stop watching", in: single)
            check(draft.values(for: single) == ["Stop watching"] && draft.text(for: single).isEmpty, "picking an option clears typed text")
            draft.setText("   ", for: single)
            check(draft.values(for: single) == ["Stop watching"], "blank text keeps the pick")

            draft.toggle("c", in: multi)
            draft.toggle("a", in: multi)
            check(draft.values(for: multi) == ["a", "c"], "multi-select answers in option order")
            draft.setText("ignored", for: multi)
            check(draft.values(for: multi) == ["a", "c"], "no free text without isOther")
            check(draft.answers(for: prompt) == nil, "still missing the open question")
            draft.setText("Because", for: open)
            check(draft.answers(for: prompt) == ["discord_remove": ["Stop watching"], "tags": ["a", "c"], "why": ["Because"]],
                  "answers cover every question")

            let multiOther = AgentQuestion(json(#"{"questionId":"m","question":"Q?","multiSelect":true,"isOther":true,"options":[{"label":"x"}]}"#))!
            var mixed = QuestionDraft()
            mixed.toggle("x", in: multiOther)
            mixed.setText("also y", for: multiOther)
            check(mixed.values(for: multiOther) == ["x", "also y"], "multi-select keeps picks alongside typed text")
            let secret = AgentQuestion(json(#"{"questionId":"s","question":"Token?","isSecret":true,"options":[]}"#))!
            var secretDraft = QuestionDraft()
            secretDraft.setText(" s3cret ", for: secret)
            check(secretDraft.values(for: secret) == [" s3cret "], "secret answers sent exactly as typed")
        }
        let askTool = ToolActivity(id: "c", name: "ask_user", arguments: #"{"questions":[{"id":"q","header":"H","question":"What do you want removed?","options":[]}]}"#,
                                   result: nil, isError: false, isRunning: true)
        check(askTool.summary == "What do you want removed?", "ask_user card summarized by its question")

        let base = ["operator.read", "operator.write", "operator.approvals", "operator.questions"]
        let legacy = #"{"code":"PAIRING_REQUIRED","reason":"scope-upgrade","requestId":"pair_1","approvedScopes":["operator.read","operator.write","operator.approvals"]}"#
        check(GatewayConnection.scopesAfterUpgradeRefusal(requested: base, details: json(legacy))
                == ["operator.read", "operator.write", "operator.approvals"],
              "scope upgrade refusal drops operator.questions for a legacy device")
        check(GatewayConnection.scopesAfterUpgradeRefusal(
                requested: base,
                details: json(#"{"reason":"scope-upgrade","approvedScopes":["operator.write","operator.approvals"]}"#))
                == ["operator.read", "operator.write", "operator.approvals"],
              "read is implied by an approved write scope")
        check(GatewayConnection.scopesAfterUpgradeRefusal(
                requested: base, details: json(#"{"reason":"not-paired","requestId":"pair_1"}"#)) == nil,
              "first pairing isn't treated as a scope upgrade")
        check(GatewayConnection.scopesAfterUpgradeRefusal(
                requested: base, details: json(#"{"reason":"scope-upgrade","approvedScopes":["operator.admin"]}"#)) == nil,
              "admin approval leaves nothing to drop")
        check(GatewayConnection.scopesAfterUpgradeRefusal(
                requested: base, details: json(#"{"reason":"scope-upgrade","approvedScopes":\#(base.description)}"#)) == nil,
              "already-approved questions scope isn't dropped")
        check(GatewayConnection.scopesAfterUpgradeRefusal(
                requested: base + ["operator.admin"], details: json(legacy)) == nil,
              "no fallback when a required scope is missing too")
        check(GatewayConnection.scopesAfterUpgradeRefusal(requested: base, details: nil) == nil,
              "errors without details don't fall back")
    }
}

/// `ApprovalHistoryModel` against a scripted Gateway: aliases, paging, cursors, errors and unsupported gateways.
@MainActor
func checkApprovalHistoryModel() async {
    func row(_ id: String, kind: String = "exec") -> JSONValue {
        json(#"{"id":"\#(id)","status":"allowed","decision":"allow-once","reason":"user","resolvedAtMs":1,"presentation":{"kind":"\#(kind)","title":"t","commandText":"c"}}"#)
    }
    var calls: [(String, JSONValue)] = []

    let aliased = ApprovalHistoryModel { method, params in
        calls.append((method, params))
        return ["approvals": .array([row("a1"), row("a2"), row("a1")])]
    }
    await aliased.load()
    check(aliased.items.map(\.id) == ["a1", "a2"] && aliased.hasLoaded && aliased.supported && !aliased.hasMore,
          "approvals alias decodes, duplicate ids dropped")
    check(calls.first?.0 == "approval.history" && calls.first?.1["limit"]?.int == 50 && calls.first?.1["cursor"] == nil
          && calls.first?.1["kind"] == nil, "first page asks for 50 without cursor or kind")
    let bare = ApprovalHistoryModel { _, _ in .array([row("b1"), json(#"{"status":"allowed"}"#)]) }
    await bare.load()
    check(bare.items.map(\.id) == ["b1"], "bare array result, records without id skipped")
    let entries = ApprovalHistoryModel { _, _ in ["entries": .array([row("e1")])] }
    await entries.load()
    check(entries.items.map(\.id) == ["e1"], "entries alias decodes")

    // Paging: cursors echoed, pages appended without duplicates, a repeated cursor stops.
    calls = []
    let paged = ApprovalHistoryModel { method, params in
        calls.append((method, params))
        switch params["cursor"]?.string {
        case nil: return ["items": .array([row("p1"), row("p2")]), "nextCursor": "c1"]
        case "c1": return ["items": .array([row("p2"), row("p3")]), "nextCursor": "c2"]
        case "c2": return ["items": .array([row("p4")]), "nextCursor": "c1"]
        default: return ["items": []]
        }
    }
    paged.pageSize = 2
    await paged.load()
    check(paged.items.map(\.id) == ["p1", "p2"] && paged.nextCursor == "c1" && calls.last?.1["limit"]?.int == 2, "page size override")
    await paged.loadMore()
    check(paged.items.map(\.id) == ["p1", "p2", "p3"] && calls.last?.1["cursor"]?.string == "c1", "loadMore echoes the cursor, dedups by id")
    await paged.loadMore()
    check(paged.items.map(\.id) == ["p1", "p2", "p3", "p4"] && !paged.hasMore, "repeated cursor stops paging")
    let callsBefore = calls.count
    await paged.loadMore()
    check(calls.count == callsBefore, "no request without a cursor")
    await paged.refresh()
    check(paged.items.map(\.id) == ["p1", "p2"] && paged.nextCursor == "c1", "refresh replaces with page 1")

    let emptyPage = ApprovalHistoryModel { _, params in
        params["cursor"] == nil ? ["items": .array([row("x1")]), "nextCursor": "more"] : ["items": [], "nextCursor": "again"]
    }
    await emptyPage.load()
    await emptyPage.loadMore()
    check(emptyPage.items.map(\.id) == ["x1"] && !emptyPage.hasMore, "empty page stops paging")

    // Kind filter goes to the server and resets paging.
    calls = []
    let filtered = ApprovalHistoryModel { method, params in
        calls.append((method, params))
        let kind = params["kind"]?.string ?? "exec"
        return ["items": .array([row("\(kind)-1", kind: kind)]), "nextCursor": params["kind"] == nil ? "n" : nil]
    }
    await filtered.load()
    await filtered.setKindFilter(.plugin)
    check(filtered.kindFilter == .plugin && calls.last?.1["kind"]?.string == "plugin" && calls.last?.1["cursor"] == nil
          && filtered.items.map(\.id) == ["plugin-1"] && !filtered.hasMore, "kind filter reloads page 1 with kind")
    await filtered.setKindFilter(.systemAgent)
    check(calls.last?.1["kind"]?.string == "system-agent" && filtered.items.first?.kind == .systemAgent, "system filter sends system-agent")
    let filterCalls = calls.count
    await filtered.setKindFilter(.systemAgent)
    check(calls.count == filterCalls, "same filter doesn't reload")
    await filtered.setKindFilter(.all)
    check(calls.last?.1["kind"] == nil, "All omits kind")

    // A stale cursor reloads page 1 once.
    var historyCalls = 0
    let stale = ApprovalHistoryModel { _, params in
        historyCalls += 1
        if params["cursor"] != nil {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid approval.history cursor", details: nil)
        }
        return ["items": .array([row("s1")]), "nextCursor": "gone"]
    }
    await stale.load()
    await stale.loadMore()
    check(historyCalls == 3 && stale.items.map(\.id) == ["s1"] && stale.loadState == .idle && stale.loadMoreState == .idle,
          "invalid cursor → one fresh reload, no error")

    // Other load-more failures keep the rows.
    let flaky = ApprovalHistoryModel { _, params in
        if params["cursor"] != nil { throw GatewayError.rpc(code: "UNAVAILABLE", message: "storage unavailable", details: nil) }
        return ["items": .array([row("f1")]), "nextCursor": "next"]
    }
    await flaky.load()
    await flaky.loadMore()
    check(flaky.items.map(\.id) == ["f1"] && flaky.loadMoreState.error == "storage unavailable" && flaky.hasMore,
          "load-more failure keeps rows and cursor")

    // Errors.
    let noScope = ApprovalHistoryModel { _, _ in
        throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.approvals",
                               details: ["code": "MISSING_SCOPE", "scope": "operator.approvals"])
    }
    await noScope.load()
    check(noScope.supported && noScope.hasLoaded && noScope.loadState.error == ApprovalHistoryModel.missingScopeMessage
          && ApprovalHistoryModel.missingScopeMessage.contains("operator.approvals"), "missing scope → approve operator.approvals message")
    let failing = ApprovalHistoryModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "ledger offline", details: nil) }
    await failing.load()
    check(failing.loadState.error == "ledger offline" && failing.supported, "other errors show the gateway's message")

    // Unsupported gateways: hello without approval.history, or UNKNOWN_METHOD.
    var requested = false
    let legacyHello = ApprovalHistoryModel(methods: { ["chat.send", "exec.approval.resolve"] }) { _, _ in
        requested = true
        return ["items": []]
    }
    await legacyHello.load()
    check(!legacyHello.supported && legacyHello.hasLoaded && !requested && legacyHello.loadState == .idle,
          "hello without approval.history → unsupported, no request, no error")
    let unknownMethod = ApprovalHistoryModel(methods: { [] }) { method, _ in
        throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
    }
    await unknownMethod.load()
    check(!unknownMethod.supported && unknownMethod.hasLoaded && unknownMethod.loadState == .idle && unknownMethod.items.isEmpty,
          "UNKNOWN_METHOD → unsupported, no error")
    let advertised = ApprovalHistoryModel(methods: { ["approval.history", "approval.get"] }) { method, _ in
        if method == "approval.get" { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: approval.get", details: nil) }
        return ["items": .array([row("g1")])]
    }
    await advertised.load()
    check(advertised.supported && advertised.items.count == 1, "advertised approval.history loads")

    // approval.get is optional: detail upgrades the row, failures keep it.
    let detailed = ApprovalHistoryModel(localDeviceId: "me") { method, params in
        switch method {
        case "approval.get":
            if params["id"]?.string == "missing" {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "approval not found", details: ["reason": "APPROVAL_NOT_FOUND"])
            }
            return ["approval": json(#"{"id":"d1","status":"allowed","decision":"allow-once","reason":"user","resolver":{"kind":"device","id":"me"},"presentation":{"kind":"exec","commandText":"full command","warningText":"careful"}}"#)]
        default:
            return ["items": .array([row("d1"), row("missing")])]
        }
    }
    await detailed.load()
    check(detailed.record("d1")?.warningText == nil, "row before approval.get")
    await detailed.loadDetail("d1")
    check(detailed.record("d1")?.commandText == "full command" && detailed.record("d1")?.warningText == "careful"
          && detailed.detailState["d1"] == .idle, "approval.get detail replaces the row")
    check(detailed.record("d1").map(detailed.decidedBy) == "This device", "model decidedBy uses its device id")
    await detailed.loadDetail("missing")
    check(detailed.record("missing")?.id == "missing" && detailed.detailState["missing"]?.error != nil, "approval.get failure keeps the row")
    check(detailed.record(nil) == nil && detailed.record("nope") == nil, "unknown ids have no record")
    await advertised.loadDetail("g1")
    check(advertised.record("g1") != nil && advertised.detailState["g1"] == .idle, "approval.get unknown method is quiet")
    var getCalled = false
    let noGet = ApprovalHistoryModel(methods: { ["approval.history"] }) { method, _ in
        if method == "approval.get" { getCalled = true }
        return ["items": .array([row("n1")])]
    }
    await noGet.load()
    await noGet.loadDetail("n1")
    check(!getCalled && noGet.record("n1") != nil, "hello without approval.get skips the request")
}

/// Stale and duplicate answers, shared by the demo and the mock (AC test cases 7, 10–12).
@MainActor
func checkApprovalOutcomes(_ gateway: GatewayStore, chat: ChatStore, label: String) async {
    print("Approval outcomes (\(label))")
    func raise(_ text: String) async -> ExecApproval? {
        let known = Set(gateway.approvals.map(\.id))
        await chat.send(text)
        _ = await waitFor("\(text) approval") { gateway.approvals.contains { !known.contains($0.id) } }
        return gateway.approvals.first { !known.contains($0.id) }
    }

    guard let full = await raise("please approve this") else { return check(false, "\(label): approval surfaced") }
    check(full.allowedDecisions == ["allow-once", "allow-always", "deny"] && Notifier.category(for: full) == "approval",
          "\(label): allowedDecisions parsed, all three actions")
    async let first = gateway.resolveApproval(id: full.id, decision: "allow-once")
    async let second = gateway.resolveApproval(id: full.id, decision: "allow-once")
    let pair = await [first, second]
    check(pair.contains(.resolved) && pair.contains(.alreadyHandled), "\(label): concurrent resolves send once (\(pair))")
    check(!gateway.approvals.contains { $0.id == full.id }, "\(label): resolved approval removed")
    let again = await gateway.resolveApproval(id: full.id, decision: "deny")
    check(again == .alreadyHandled,
          "\(label): acting again after success is a quiet no-op")
    _ = await waitFor("\(label) run", timeout: 20) { !chat.isRunning }

    guard let once = await raise("approve once-only") else { return check(false, "\(label): once-only approval surfaced") }
    check(once.allowedDecisions == ["allow-once", "deny"] && !once.allowsAlways && Notifier.category(for: once) == "approval-once",
          "\(label): approve once-only leaves out Always allow")
    let always = await gateway.resolveApproval(once, decision: "allow-always")
    check(always == .allowAlwaysUnavailable, "\(label): allow-always → unavailable (\(always))")
    check(gateway.approvals.contains { $0.id == once.id }, "\(label): approval stays pending")
    check(gateway.lastError == "Always allow isn't available for this command.", "\(label): banner error in lastError")
    let allowed = await gateway.resolveApproval(once, decision: "allow-once")
    check(allowed == .resolved && !gateway.approvals.contains { $0.id == once.id }, "\(label): then Allow once succeeds (\(allowed))")
    _ = await waitFor("\(label) run", timeout: 20) { !chat.isRunning }

    let missingId = "approval_missing_\(UUID().uuidString.prefix(6))"
    let missing = await gateway.resolveApproval(id: missingId, decision: "deny")
    check(missing == .expired, "\(label): unknown id → expired (\(missing))")
    let missingAgain = await gateway.resolveApproval(id: missingId, decision: "allow-once")
    check(missingAgain == .alreadyHandled, "\(label): acting again on an expired approval is a quiet no-op (\(missingAgain))")

    // A resolve that's out of time or cancelled never reaches the Gateway, and the approval stays pending.
    guard let late = await raise("please approve this") else { return check(false, "\(label): approval surfaced") }
    let pastDeadline = await gateway.resolveApproval(id: late.id, decision: "allow-once", connectWithin: 0)
    check(pastDeadline == .unreachable, "\(label): deadline already passed → unreachable (\(pastDeadline))")
    let cancelled = Task { await gateway.resolveApproval(id: late.id, decision: "allow-once") }
    cancelled.cancel()
    let cancelledOutcome = await cancelled.value
    check(cancelledOutcome == .unreachable, "\(label): cancelled resolve → unreachable (\(cancelledOutcome))")
    // Negative window: a cancelled resolve must not send an RPC.
    try? await Task.sleep(for: .milliseconds(500))
    check(gateway.approvals.contains { $0.id == late.id }, "\(label): neither sent an RPC, approval still pending")
    _ = await waitFor("\(label) reconnect") { gateway.state.isConnected }
    let answered = await gateway.resolveApproval(id: late.id, decision: "deny")
    check(answered == .resolved && !gateway.approvals.contains { $0.id == late.id }, "\(label): a later action still resolves it (\(answered))")
    _ = await waitFor("\(label) run", timeout: 20) { !chat.isRunning }
}

/// Mock-only approval paths (AC test cases 9–11, 13, 14).
@MainActor
func checkLiveApprovals(profile: GatewayProfile, gateway: GatewayStore, chat: ChatStore) async {
    print("Approval resolution (live)")
    func raise(_ text: String) async -> ExecApproval? {
        let known = Set(gateway.approvals.map(\.id))
        await chat.send(text)
        _ = await waitFor("\(text) approval") { gateway.approvals.contains { !known.contains($0.id) } }
        return gateway.approvals.first { !known.contains($0.id) }
    }

    // A store that just started, like a background launch: resolves once connected.
    guard let pending = await raise("please approve this") else { return check(false, "approval surfaced") }
    let cold = GatewayStore(profile: profile)
    cold.start()
    let started = Date()
    let outcome = await cold.resolveApproval(id: pending.id, decision: "deny")
    let coldElapsed = Duration.seconds(Date().timeIntervalSince(started))
    check(outcome == .resolved, "cold store resolves by id (\(outcome))")
    checkBudget(coldElapsed, .seconds(25), hardLimit: .seconds(60),
                "cold store resolves within the budget (\(coldElapsed.formatted(.units(allowed: [.milliseconds]))))")
    let cleared = await waitFor("exec.approval.resolved from another client") { !gateway.approvals.contains { $0.id == pending.id } }
    check(cleared, "resolved by another client → removed from this store")
    check(cold.approvals.isEmpty, "cold store keeps no approval")
    // Another device retrying: the same decision is idempotent, a different one was answered elsewhere.
    let other = GatewayStore(profile: profile)
    other.start()
    let identical = await other.resolveApproval(id: pending.id, decision: "deny")
    check(identical == .resolved, "identical retry from another client → success")
    let conflict = await other.resolveApproval(id: pending.id, decision: "allow-once")
    check(conflict == .alreadyHandled, "different decision after answering here → quiet no-op (\(conflict))")
    let fresh = GatewayStore(profile: profile)
    fresh.start()
    let conflictFresh = await fresh.resolveApproval(id: pending.id, decision: "allow-once")
    check(conflictFresh == .answeredElsewhere(decision: nil), "different decision from a fresh client → answered elsewhere (\(conflictFresh))")
    check(fresh.approvals.isEmpty, "answered elsewhere leaves nothing pending")
    let freshAgain = await fresh.resolveApproval(id: pending.id, decision: "allow-once")
    check(freshAgain == .alreadyHandled, "acting again after answered elsewhere → quiet no-op (\(freshAgain))")
    for store in [cold, other, fresh] { store.stop() }
    _ = await waitFor("approval run", timeout: 20) { !chat.isRunning }

    // Gateway B's approval id sent to A never reaches B; A reads it as not found.
    guard let mine = await raise("please approve this") else { return check(false, "approval surfaced") }
    let foreign = await gateway.resolveApproval(id: "approval_on_gateway_b", decision: "allow-once")
    check(foreign == .expired && gateway.approvals.contains { $0.id == mine.id }, "another gateway's id → not found, own approval untouched")
    check(Notifier.interpret(actionIdentifier: "approve-once", categoryIdentifier: "approval",
                             userInfo: ["gateway": UUID().uuidString, "approval": mine.id])
          != .resolve(gatewayId: gateway.id, approvalId: mine.id, decision: "allow-once"), "action routes only to the notification's gateway")
    await gateway.resolveApproval(mine, decision: "deny")
    _ = await waitFor("approval run", timeout: 20) { !chat.isRunning }

    // The mock's short-lived approval expires after 3 s.
    guard let short = await raise("approve short-lived") else { return check(false, "short-lived approval surfaced") }
    // Wait out the approval's wall-clock expiry (mock: 3 s); expiry is time-driven.
    try? await Task.sleep(for: .seconds(max(0, (short.expiresAt ?? Date()).timeIntervalSinceNow) + 0.3))
    check(short.isExpired(), "short-lived approval past expiresAt")
    let expired = await gateway.resolveApproval(short, decision: "allow-once")
    check(expired == .expired && !gateway.approvals.contains { $0.id == short.id }, "resolve after expiry → expired, removed (\(expired))")
    let viaRPC = GatewayStore(profile: profile)
    viaRPC.start()
    let expiredRPC = await viaRPC.resolveApproval(id: short.id, decision: "allow-once")
    check(expiredRPC == .expired, "Gateway reports the expired id as not found")
    let expiredAgain = await viaRPC.resolveApproval(id: short.id, decision: "deny")
    check(expiredAgain == .alreadyHandled, "acting again after expired → quiet no-op (\(expiredAgain))")
    viaRPC.stop()
    _ = await waitFor("approval run", timeout: 20) { !chat.isRunning }
}
